module MiniSidekiq
  class Worker
    EMPTY_POLL_SLEEP = 0.1

    class ShutdownFlag
      def initialize
        @flag = false
      end

      def set!
        @flag = true
      end

      def true?
        @flag
      end
    end

    def initialize(concurrency: MiniSidekiq.concurrency)
      @concurrency = concurrency
      @shutdown = ShutdownFlag.new
      @threads = []
    end

    def run
      install_signal_handlers
      MiniSidekiq.logger.info("[mini_sidekiq] starting (concurrency=#{@concurrency})")

      @threads << Thread.new { Scheduler.new(@shutdown).run }
      @threads << Thread.new { Cron.new(@shutdown).run }
      @concurrency.times { @threads << Thread.new { execute_loop } }

      @threads.each(&:join)
      MiniSidekiq.logger.info("[mini_sidekiq] shutdown complete")
    end

    private

    def install_signal_handlers
      %w[INT TERM].each do |sig|
        Signal.trap(sig) { @shutdown.set! }
      end
    end

    def execute_loop
      keys = QUEUES.map { |q| MiniSidekiq.queue_key(q) }
      until @shutdown.true?
        json = pop_next(keys)
        if json
          execute(json)
        else
          sleep EMPTY_POLL_SLEEP
        end
      end
    rescue StandardError => e
      MiniSidekiq.error_handler.call(e, { "jid" => nil, "class" => "<executor-loop>" })
      retry unless @shutdown.true?
    end

    # Iterates queue keys in priority order (high → default → low), returning
    # the first available payload via RPOP. Returns nil if all queues are empty.
    #
    # We deliberately avoid BRPOP because the local Redis 8.6.2 build does not
    # honor BRPOP's per-command timeout argument on empty lists, which would
    # make graceful shutdown wait for the full socket-read grace period.
    def pop_next(keys)
      keys.each do |key|
        json = MiniSidekiq.redis.rpop(key)
        return json if json
      end
      nil
    end

    def execute(json)
      payload = parse_payload(json)
      return unless payload

      klass = resolve_class(payload)
      return unless klass

      begin
        klass.new.perform(*payload["args"])
      rescue StandardError => e
        MiniSidekiq.error_handler.call(e, payload)
        handle_failure(payload, e)
      end
    end

    def parse_payload(json)
      JSON.parse(json)
    rescue JSON::ParserError => e
      payload = { "jid" => nil, "class" => "<corrupt>", "raw" => json, "attempts" => MAX_ATTEMPTS }
      MiniSidekiq.error_handler.call(e, payload)
      bury(payload, e)
      nil
    end

    def resolve_class(payload)
      Object.const_get(payload["class"])
    rescue NameError => e
      MiniSidekiq.error_handler.call(e, payload)
      payload["attempts"] = MAX_ATTEMPTS
      bury(payload, e)
      nil
    end

    def handle_failure(payload, exception)
      payload["attempts"]      = (payload["attempts"] || 0) + 1
      payload["error_class"]   = exception.class.name
      payload["error_message"] = exception.message

      if payload["attempts"] < MAX_ATTEMPTS
        retry_at = Time.now.to_f + (BACKOFF_SECONDS * payload["attempts"])
        MiniSidekiq.redis.zadd(MiniSidekiq.retry_key, retry_at, JSON.dump(payload))
      else
        bury(payload, exception)
      end
    end

    def bury(payload, exception = nil)
      if exception
        payload["error_class"]   = exception.class.name
        payload["error_message"] = exception.message
      end

      MiniSidekiq.redis.lpush(MiniSidekiq.dead_key, JSON.dump(payload))
      MiniSidekiq.redis.ltrim(MiniSidekiq.dead_key, 0, DEAD_LIST_LIMIT - 1)
    end
  end
end
