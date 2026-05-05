redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379")
sidekiq_redis = { url: "#{redis_url}/2" }

Sidekiq.configure_server { |config| config.redis = sidekiq_redis }
Sidekiq.configure_client { |config| config.redis = sidekiq_redis }

Rails.application.config.active_job.queue_adapter = :sidekiq
