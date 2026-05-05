module MiniSidekiq
  class Client
    def self.push(class_name:, args: [], queue: DEFAULT_QUEUE, run_at: nil, attempts: 0, jid: nil)
      queue = queue.to_s
      raise ArgumentError, "unknown queue: #{queue}" unless QUEUES.include?(queue)

      payload = {
        "jid"           => jid || SecureRandom.hex(6),
        "class"         => class_name.to_s,
        "args"          => args,
        "queue"         => queue,
        "enqueued_at"   => Time.now.to_f,
        "attempts"      => attempts,
        "error_class"   => nil,
        "error_message" => nil
      }

      json = JSON.dump(payload)

      if run_at
        MiniSidekiq.redis.zadd(MiniSidekiq.schedule_key, run_at.to_f, json)
      else
        MiniSidekiq.redis.lpush(MiniSidekiq.queue_key(queue), json)
      end

      payload
    end
  end
end
