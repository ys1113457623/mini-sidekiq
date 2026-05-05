require_relative "test_case"

module MiniSidekiq
  class ClientTest < ::MiniSidekiqTestCase
    test "push enqueues to default queue list as JSON" do
      Client.push(class_name: "TestJob", args: [1, "a"])
      json = MiniSidekiq.redis.lrange(MiniSidekiq.queue_key("default"), 0, -1).first
      payload = JSON.parse(json)

      assert_equal "TestJob", payload["class"]
      assert_equal [1, "a"], payload["args"]
      assert_equal "default", payload["queue"]
      assert_equal 0, payload["attempts"]
      assert_match(/\A[0-9a-f]{12}\z/, payload["jid"])
    end

    test "push respects queue argument" do
      Client.push(class_name: "TestJob", queue: "high")
      assert_equal 1, MiniSidekiq.redis.llen(MiniSidekiq.queue_key("high"))
      assert_equal 0, MiniSidekiq.redis.llen(MiniSidekiq.queue_key("default"))
    end

    test "push with run_at writes to schedule zset with correct score" do
      ts = Time.now.to_f + 60
      Client.push(class_name: "TestJob", args: [], queue: "high", run_at: ts)

      members = MiniSidekiq.redis.zrange(MiniSidekiq.schedule_key, 0, -1, with_scores: true)
      assert_equal 1, members.size
      assert_in_delta ts, members.first.last, 0.001

      payload = JSON.parse(members.first.first)
      assert_equal "high", payload["queue"]
    end

    test "rejects unknown queue name" do
      assert_raises(ArgumentError) do
        Client.push(class_name: "TestJob", queue: "weird")
      end
    end
  end
end
