class Timberline
  # Queue is the heart and soul of Timberline, which makes sense
  # considering that it's a queueing library. This object represents
  # a queue in redis (really just a list of strings) and is responsible
  # for reading to the queue, writing from the queue, maintaining queue
  # statistics, and managing other queue actions (like pausing and deleting).
  #
  # @attr_reader [String] queue_name the name of this queue
  # @attr_reader [Integer] read_timeout how long this queue should wait, in
  #   seconds, before determining that there isn't anything to read off of the
  #   queue.
  #
  class Queue
    attr_reader :queue_name, :read_timeout

    # Build a new Queue object.
    #
    # @param [String] queue_name the redis queue that this object should represent
    # @param [Hash] opts the options for creating this queue
    # @option opts [Integer] :read_timeout the read_timeout for this queue.
    #   defaults to 0 (which effectively disables the timeout).
    # @option opts [boolean] :hidden whether this queue should be hidden from
    #   Timberline's #all_queues list. Defaults to false.
    # @raise [ArgumentError] if queue_name is not provided
    # @return [Queue]
    #
    def initialize(queue_name, opts = {})
      read_timeout = opts.fetch(:read_timeout, 0)
      hidden = opts.fetch(:hidden, false)
      if queue_name.nil?
        raise ArgumentError.new("Queue name must be provided.")
      end
      @queue_name = queue_name
      @read_timeout = read_timeout
      @redis = Timberline.redis
      unless hidden
        @redis.sadd "timberline_queue_names", queue_name
      end
    end

    # Delete this queue, removing it from redis and all other references to it
    # from Timberline.
    #
    # @return as Redis#srem
    #
    def delete
      @redis.del @queue_name
      @redis.keys("#{@queue_name}:*").each do |key|
        @redis.del key
      end
      @redis.srem "timberline_queue_names", @queue_name
    end

    # The current number of items on the queue waiting to be processed.
    #
    # @return [Integer]
    #
    def length
      @redis.llen @queue_name
    end

    # Uses a blocking read from redis to pull the next item off the queue. If
    # the queue is paused, this method will block until the queue is unpaused,
    # at which point it will move on to the blocking read.
    #
    # @return [Timberline::Envelope] the Envelope representation of the item
    #   that was pulled off the queue, or nil if the read timed out.
    #
    def pop
      block_while_paused

      br_tuple = @redis.brpop(@queue_name, read_timeout)
      envelope_string = br_tuple.nil? ? nil : br_tuple[1]
      if envelope_string.nil?
        nil
      else
        Envelope.from_json(envelope_string)
      end
    end

    # Pushes the specified data onto the queue.
    #
    # @param [#to_json, Timberline::Envelope] contents either contents that can
    #   be converted to JSON and stuffed in an Envelope, or an Envelope itself
    #   that needs to be put on the queue.  
    # @param [Hash] metadata metadata that will be attached to the envelope for
    # contents.
    #
    def push(contents, metadata = {})
      case contents
      when Envelope
        @redis.lpush @queue_name, contents
      else
        @redis.lpush @queue_name, wrap(contents, metadata)
      end
    end

    # Puts this queue into paused mode.
    # @see Timberline::Queue#pop
    #
    def pause
      @redis[attr("paused")] = "true"
    end

    # Takes this queue back out of paused mode.
    # @see Timberline::Queue#pop
    #
    def unpause
      @redis[attr("paused")] = "false"
    end

    # Indicates whether or not this queue is currently in paused mode.
    # @return [boolean]
    #
    def paused?
      @redis[attr("paused")] == "true"
    end

    # Given a key, create a string namespaced to this queue name.
    # This method is used to keep redis keys tidy.
    #
    # @return [String]
    #
    def attr(key)
      "#{@queue_name}:#{key}"
    end

    # The number of items that have encountered fatal errors on the queue
    # during the last [stat_timeout] minutes.
    #
    # @return [Integer]
    #
    def number_errors
      Timberline.redis.xcard attr("error_stats")
    end

    # The number of items that have been retried on the queue
    # during the last [stat_timeout] minutes.
    #
    # @return [Integer]
    #
    def number_retries
      Timberline.redis.xcard attr("retry_stats")
    end

    # The number of items that were processed successfully for this queue
    # during the last [stat_timeout] minutes.
    #
    # @return [Integer]
    #
    def number_successes
      Timberline.redis.xcard attr("success_stats")
    end

    # Given all of the successful jobs that were executed in the last
    # [stat_timeout] minutes, determine how long on average those jobs
    # took to execute.
    #
    # @return [Float] the average execution time for successful jobs in the last
    #   [stat_timeout] minutes.
    #
    def average_execution_time
      successes = Timberline.redis.xmembers(attr("success_stats")).map { |item| Envelope.from_json(item)}
      times = successes.map do |item|
        if item.finished_processing_at
          item.finished_processing_at.to_f - item.started_processing_at.to_f
        elsif item.fatal_error_at
          item.fatal_error_at.to_f - item.started_processing_at.to_f
        else
          nil
        end
      end
      times.reject! { |t| t.nil? }
      if times.size == 0
        0
      else
        times.inject(0, :+) / times.size.to_f
      end
    end

    # Given an item that needs to be retried, increment the retry count,
    # add any appropriate metadata about the retry, and push it back onto
    # the queue. If the item has already been retried the maximum number of
    # times, pass it on to error_item instead.
    #
    # @see Timberline::Queue#error_item
    # 
    # @param [Envelope] item an item that needs to be retried
    #
    def retry_item(item)
      if (item.retries < Timberline.max_retries)
        item.retries += 1
        item.last_tried_at = Time.now.to_f
        add_retry_stat(item)
        push(item)
      else
        error_item(item)
      end
    end

    # Given an item that errored out in processing, add any appropriate metadata
    # about the error, track it as a statistic, and push it onto the error queue.
    #
    # @param [Envelope] item an item that has fatally errored
    #
    def error_item(item)
      item.fatal_error_at = Time.now.to_f
      add_error_stat(item)
      self.error_queue.push(item)
    end

    # Stores an item from the queue that was retried so we can keep track
    # of things like how many retries have been attempted on this queue, etc.
    #
    # @param [Envelope] item an item that fatally errored on this queue
    #
    def add_retry_stat(item)
      add_stat_for_key(attr("retry_stats"), item)
    end

    # Stores an item from the queue that fatally errored so we can keep track
    # of things like how many errors have occurred on this queue, etc.
    #
    # @param [Envelope] item an item that fatally errored on this queue
    #
    def add_error_stat(item)
      add_stat_for_key(attr("error_stats"), item)
    end

    # Stores a successfully processed queue item as a statistic so we can keep
    # track of things like average execution time, number of successes, etc.
    #
    # @param [Envelope] item an item that was processed successfully for this
    #   queue
    #
    def add_success_stat(item)
      add_stat_for_key(attr("success_stats"), item)
    rescue Exception => e
      $stderr.puts "Success Stat Error: #{e.inspect}, Item: #{item.inspect}"
    end

    # @return [Timberline::Queue] a (hidden) Queue object where this queue's
    #  errors are pushed.
    #
    def error_queue
      @error_queue ||= Timberline.queue(attr("errors"), hidden: true)
    end

    private

    def add_stat_for_key(key, item)
      Timberline.redis.xadd key, item, Time.now + Timberline.stat_timeout_seconds
    end

    def next_id
      Timberline.redis.incr attr("id_seq")
    end

    def wrap(contents, metadata)
      envelope = Envelope.new
      envelope.contents = contents
      metadata.each do |key, value|
        envelope.send("#{key.to_s}=", value)
      end

      # default metadata
      envelope.item_id = next_id
      envelope.retries = 0
      envelope.submitted_at = Time.now.to_f
      envelope.origin_queue = @queue_name

      envelope
    end

    def block_while_paused
      while(self.paused?)
        sleep(1)
      end
    end
  end
end
