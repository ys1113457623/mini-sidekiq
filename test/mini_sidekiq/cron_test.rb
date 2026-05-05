require_relative "test_case"

class HourlyCronJob
  include MiniSidekiq::Job
  def perform; end
end

# FakeShutdownFlag may already be defined by scheduler_test; re-opening is safe.
class FakeShutdownFlag
  def true?; false; end
end

module MiniSidekiq
  class CronTest < ::MiniSidekiqTestCase
    test "register parses cron expression and stores entry" do
      Cron.register("hourly", "0 * * * *", HourlyCronJob)
      assert_equal 1, Cron.entries.size
      assert_equal "hourly", Cron.entries.first.name
    end

    test "register raises on invalid expression" do
      assert_raises(ArgumentError) do
        Cron.register("bad", "not a cron", HourlyCronJob)
      end
    end

    test "tick enqueues when next-fire is past, then recomputes" do
      Cron.register("hourly", "0 * * * *", HourlyCronJob, queue: :default)
      entry = Cron.entries.first
      entry.next_fire_at = Time.now.to_f - 1

      Cron.new(FakeShutdownFlag.new, entries: Cron.entries).tick

      assert_equal 1, MiniSidekiq.redis.llen(MiniSidekiq.queue_key("default"))
      assert entry.next_fire_at > Time.now.to_f, "next_fire_at should be recomputed into the future"
    end

    test "tick skips when next-fire is in the future" do
      Cron.register("hourly", "0 * * * *", HourlyCronJob)
      Cron.new(FakeShutdownFlag.new, entries: Cron.entries).tick

      assert_equal 0, MiniSidekiq.redis.llen(MiniSidekiq.queue_key("default"))
    end
  end
end
