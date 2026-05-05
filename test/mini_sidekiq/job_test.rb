require_relative "test_case"

class JobTestEmail
  include MiniSidekiq::Job
  mini_sidekiq_options queue: :high

  def perform(*); end
end

class JobTestDefault
  include MiniSidekiq::Job

  def perform(*); end
end

class JobTestInlineRecorder
  class << self
    attr_accessor :calls
  end
  self.calls = []
end

class JobTestInline
  include MiniSidekiq::Job

  def perform(value)
    JobTestInlineRecorder.calls << value
    "ran with #{value}"
  end
end

module MiniSidekiq
  class JobTest < ::MiniSidekiqTestCase
    test "perform_async pushes to configured queue" do
      JobTestEmail.perform_async("a@b.com")
      json = MiniSidekiq.redis.lrange(MiniSidekiq.queue_key("high"), 0, -1).first
      payload = JSON.parse(json)

      assert_equal "JobTestEmail", payload["class"]
      assert_equal ["a@b.com"], payload["args"]
    end

    test "default queue is :default when no options set" do
      JobTestDefault.perform_async
      assert_equal 1, MiniSidekiq.redis.llen(MiniSidekiq.queue_key("default"))
    end

    test "perform_in lands in schedule zset with future score" do
      before = Time.now.to_f
      JobTestEmail.perform_in(60, "x")

      members = MiniSidekiq.redis.zrange(MiniSidekiq.schedule_key, 0, -1, with_scores: true)
      assert_equal 1, members.size
      score = members.first.last
      assert score > before + 59, "expected score > now+59, got #{score - before}"
      assert score < before + 61, "expected score < now+61, got #{score - before}"
    end

    test "perform_at lands in schedule zset with the exact score" do
      target = Time.now + 120
      JobTestEmail.perform_at(target, "x")

      members = MiniSidekiq.redis.zrange(MiniSidekiq.schedule_key, 0, -1, with_scores: true)
      assert_equal 1, members.size
      assert_in_delta target.to_f, members.first.last, 0.001
    end

    test "perform_inline runs synchronously without touching Redis" do
      JobTestInlineRecorder.calls = []
      result = JobTestInline.perform_inline("hello")

      assert_equal ["hello"], JobTestInlineRecorder.calls
      assert_equal "ran with hello", result
      assert_equal 0, MiniSidekiq.redis.llen(MiniSidekiq.queue_key("default"))
      assert_equal 0, MiniSidekiq.redis.zcard(MiniSidekiq.schedule_key)
    end

    test "perform_inline re-raises exceptions" do
      failing = Class.new do
        include MiniSidekiq::Job
        def perform(*); raise "boom"; end
      end
      assert_raises(RuntimeError) { failing.perform_inline }
    end
  end
end
