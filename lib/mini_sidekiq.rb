require "redis"
require "logger"
require "json"
require "securerandom"
require "fugit"

module MiniSidekiq
  MAX_ATTEMPTS    = 3
  BACKOFF_SECONDS = 5
  QUEUES          = %w[high default low].freeze
  DEFAULT_QUEUE   = "default"
  KEY_PREFIX      = "mini_sidekiq".freeze
  DEAD_LIST_LIMIT = 1000

  class << self
    attr_writer :redis_url, :concurrency, :error_handler, :logger

    def configure
      yield self
    end

    def redis_url
      @redis_url ||= ENV.fetch("MINI_SIDEKIQ_REDIS_URL", "redis://localhost:6379/0")
    end

    def concurrency
      @concurrency ||= 5
    end

    def logger
      @logger ||= Logger.new($stdout)
    end

    def error_handler
      @error_handler ||= ->(exception, ctx) {
        logger.error(
          "[mini_sidekiq] #{exception.class}: #{exception.message} " \
          "jid=#{ctx['jid']} class=#{ctx['class']}"
        )
      }
    end

    def redis
      Thread.current[:mini_sidekiq_redis] ||= Redis.new(url: redis_url, timeout: 5.0)
    end

    def queue_key(name)
      "#{KEY_PREFIX}:queue:#{name}"
    end

    def schedule_key
      "#{KEY_PREFIX}:schedule"
    end

    def retry_key
      "#{KEY_PREFIX}:retry"
    end

    def dead_key
      "#{KEY_PREFIX}:dead"
    end
  end
end
