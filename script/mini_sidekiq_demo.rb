# End-to-end demo for Mini-Sidekiq.
#
# Run inside the web container:
#   docker compose exec web bundle exec ruby script/mini_sidekiq_demo.rb
#
# Or natively:
#   MINI_SIDEKIQ_REDIS_URL=redis://localhost:6379/0 \
#     bundle exec ruby script/mini_sidekiq_demo.rb
#
# Boots Rails (so lib/mini_sidekiq autoloads), enqueues 5 jobs across the three
# queues (one of which fails to demonstrate the retry path), runs the worker
# for ~6 seconds, then prints the resulting Redis state.

ENV["MINI_SIDEKIQ_REDIS_URL"] ||= ENV["REDIS_URL"] || "redis://localhost:6379/0"
require File.expand_path("../config/environment", __dir__)

# Reset state for repeatability.
[
  MiniSidekiq.queue_key("high"),
  MiniSidekiq.queue_key("default"),
  MiniSidekiq.queue_key("low"),
  MiniSidekiq.schedule_key,
  MiniSidekiq.retry_key,
  MiniSidekiq.dead_key
].each { |k| MiniSidekiq.redis.del(k) }
MiniSidekiq::Cron.reset!

# Silence the default error logger so the retry-path output stays readable.
MiniSidekiq.error_handler = ->(*) {}

class DemoJob
  include MiniSidekiq::Job
  mini_sidekiq_options queue: :default

  def perform(label)
    puts "  ▶ default ▶ #{label.ljust(20)} at #{Time.now.strftime('%H:%M:%S.%L')}"
  end
end

class HighPriorityJob
  include MiniSidekiq::Job
  mini_sidekiq_options queue: :high

  def perform(label)
    puts "  ▶ HIGH    ▶ #{label.ljust(20)} at #{Time.now.strftime('%H:%M:%S.%L')}"
  end
end

class FlakyJob
  include MiniSidekiq::Job

  def perform(label)
    puts "  ▶ flaky   ▶ #{label.ljust(20)} at #{Time.now.strftime('%H:%M:%S.%L')} (raising)"
    raise "intentional failure"
  end
end

puts "=== Mini-Sidekiq end-to-end demo ==="
puts "Redis: #{ENV['MINI_SIDEKIQ_REDIS_URL']}"
puts ""

puts "Enqueuing five jobs:"
puts "  - HighPriorityJob \"priority-A\"           [queue:high, immediate]"
puts "  - DemoJob         \"immediate\"            [queue:default, immediate]"
puts "  - DemoJob         \"+1s delayed\"          [queue:default, perform_in(1)]"
puts "  - DemoJob         \"+2s delayed\"          [queue:default, perform_in(2)]"
puts "  - FlakyJob        \"will fail then retry\" [queue:default, immediate, raises]"
puts ""

HighPriorityJob.perform_async("priority-A")
DemoJob.perform_async("immediate")
DemoJob.perform_in(1, "+1s delayed")
DemoJob.perform_in(2, "+2s delayed")
FlakyJob.perform_async("will fail then retry")

puts "Starting worker (concurrency=1, so priority-order is visible) for 6 seconds..."
puts "------------------------------------------------------------------"

worker = MiniSidekiq::Worker.new(concurrency: 1)
t = Thread.new { worker.run }
sleep 6

puts "------------------------------------------------------------------"
puts "Sending SIGINT for graceful shutdown..."
Process.kill("INT", Process.pid)
t.join

puts ""
puts "=== Final Redis state ==="
printf "  %-15s %d\n", "queue:high",    MiniSidekiq.redis.llen(MiniSidekiq.queue_key("high"))
printf "  %-15s %d\n", "queue:default", MiniSidekiq.redis.llen(MiniSidekiq.queue_key("default"))
printf "  %-15s %d\n", "queue:low",     MiniSidekiq.redis.llen(MiniSidekiq.queue_key("low"))
printf "  %-15s %d\n", "schedule",      MiniSidekiq.redis.zcard(MiniSidekiq.schedule_key)
printf "  %-15s %d\n", "retry",         MiniSidekiq.redis.zcard(MiniSidekiq.retry_key)
printf "  %-15s %d\n", "dead",          MiniSidekiq.redis.llen(MiniSidekiq.dead_key)

retried = MiniSidekiq.redis.zrange(MiniSidekiq.retry_key, 0, -1, with_scores: true).first
if retried
  payload = JSON.parse(retried.first)
  puts ""
  puts "FlakyJob is in the retry zset, scheduled for #{Time.at(retried.last)} " \
       "(attempts=#{payload['attempts']}, last error: #{payload['error_class']}: #{payload['error_message']})"
end

puts ""
puts "=== Demo complete ==="
