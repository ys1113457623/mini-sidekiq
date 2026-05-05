module MiniSidekiq
  class Scheduler
    POLL_INTERVAL = 1.0

    def initialize(shutdown_flag)
      @shutdown = shutdown_flag
    end

    def run
      until @shutdown.true?
        drain_once
        sleep POLL_INTERVAL
      end
    end

    def drain_once(now = Time.now.to_f)
      drain(MiniSidekiq.schedule_key, now)
      drain(MiniSidekiq.retry_key, now)
    end

    private

    def drain(zset_key, now)
      due = MiniSidekiq.redis.zrangebyscore(zset_key, "-inf", now)
      due.each do |json|
        begin
          payload = JSON.parse(json)
          queue_key = MiniSidekiq.queue_key(payload["queue"])

          MiniSidekiq.redis.multi do |m|
            m.zrem(zset_key, json)
            m.lpush(queue_key, json)
          end
        rescue JSON::ParserError => e
          ctx = { "jid" => nil, "class" => "<corrupt>", "raw" => json }
          MiniSidekiq.error_handler.call(e, ctx)
          MiniSidekiq.redis.zrem(zset_key, json)
        end
      end
    end
  end
end
