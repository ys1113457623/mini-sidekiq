ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../config/environment", __dir__)
require "minitest/autorun"
require "active_support/test_case"

# This file deliberately bypasses test/test_helper.rb so the mini_sidekiq tests
# do not depend on the Rails test database (`rails/test_help` triggers a schema
# check against PostgreSQL). The only external dependency these tests need is
# Redis on the URL specified by MINI_SIDEKIQ_TEST_REDIS_URL (default DB 15).
class MiniSidekiqTestCase < ActiveSupport::TestCase
  setup do
    MiniSidekiq.redis_url = ENV.fetch("MINI_SIDEKIQ_TEST_REDIS_URL", "redis://localhost:6379/15")
    Thread.current[:mini_sidekiq_redis] = nil
    MiniSidekiq.redis.flushdb
    MiniSidekiq::Cron.reset!
    MiniSidekiq.error_handler = ->(*) {}
  end
end
