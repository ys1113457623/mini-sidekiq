require_relative "test_case"

class FakeShutdownFlag
  def true?; false; end
end

module MiniSidekiq
  class SchedulerTest < ::MiniSidekiqTestCase
    test "drain_once moves due entry to its queue" do
      payload = { "class" => "TestJob", "args" => [], "queue" => "high",
                  "attempts" => 0, "jid" => "x" }
      json = JSON.dump(payload)
      MiniSidekiq.redis.zadd(MiniSidekiq.schedule_key, Time.now.to_f - 1, json)

      Scheduler.new(FakeShutdownFlag.new).drain_once

      assert_equal 0, MiniSidekiq.redis.zcard(MiniSidekiq.schedule_key)
      queued = MiniSidekiq.redis.lrange(MiniSidekiq.queue_key("high"), 0, -1).first
      assert_equal json, queued
    end

    test "drain_once leaves not-yet-due entries in place" do
      payload = { "class" => "TestJob", "args" => [], "queue" => "default",
                  "attempts" => 0, "jid" => "x" }
      json = JSON.dump(payload)
      MiniSidekiq.redis.zadd(MiniSidekiq.schedule_key, Time.now.to_f + 60, json)

      Scheduler.new(FakeShutdownFlag.new).drain_once

      assert_equal 1, MiniSidekiq.redis.zcard(MiniSidekiq.schedule_key)
      assert_equal 0, MiniSidekiq.redis.llen(MiniSidekiq.queue_key("default"))
    end

    test "drain_once also moves entries from the retry zset" do
      payload = { "class" => "TestJob", "args" => [], "queue" => "low",
                  "attempts" => 1, "jid" => "x" }
      json = JSON.dump(payload)
      MiniSidekiq.redis.zadd(MiniSidekiq.retry_key, Time.now.to_f - 1, json)

      Scheduler.new(FakeShutdownFlag.new).drain_once

      assert_equal 0, MiniSidekiq.redis.zcard(MiniSidekiq.retry_key)
      assert_equal 1, MiniSidekiq.redis.llen(MiniSidekiq.queue_key("low"))
    end
  end
end
