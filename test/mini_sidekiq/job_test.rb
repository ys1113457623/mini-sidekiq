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
  end
end
