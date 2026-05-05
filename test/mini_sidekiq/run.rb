# Runner for mini_sidekiq tests. Bypasses `bin/rails test` so the suite does not
# require a running PostgreSQL test database. Redis (DB 15 by default) is the
# only external dependency.
#
# Usage:
#   bundle exec ruby -Itest test/mini_sidekiq/run.rb
#
# Override the test Redis URL with MINI_SIDEKIQ_TEST_REDIS_URL.

Dir[File.join(__dir__, "*_test.rb")].sort.each { |path| require path }
