require_relative "test_case"

class WorkerTestFailingJob
  @@calls = 0
  def self.calls; @@calls; end
  def self.reset!; @@calls = 0; end

  def perform(*)
    @@calls += 1
    raise "boom"
  end
end

class WorkerTestOkJob
  @@calls = []
  def self.calls; @@calls; end
  def self.reset!; @@calls = []; end

  def perform(*args)
    @@calls << args
  end
end

module MiniSidekiq
  class WorkerTest < ::MiniSidekiqTestCase
    setup do
      WorkerTestFailingJob.reset!
      WorkerTestOkJob.reset!
    end

    test "successful job runs and leaves no retry/dead state" do
      payload = { "jid" => "j", "class" => "WorkerTestOkJob", "args" => ["hi"],
                  "queue" => "default", "attempts" => 0 }
      Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))

      assert_equal [["hi"]], WorkerTestOkJob.calls
      assert_equal 0, MiniSidekiq.redis.zcard(MiniSidekiq.retry_key)
      assert_equal 0, MiniSidekiq.redis.llen(MiniSidekiq.dead_key)
    end

    test "first failure pushes to retry zset with backoff" do
      payload = { "jid" => "j", "class" => "WorkerTestFailingJob", "args" => [],
                  "queue" => "default", "attempts" => 0 }
      before = Time.now.to_f
      Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))

      assert_equal 1, WorkerTestFailingJob.calls
      assert_equal 1, MiniSidekiq.redis.zcard(MiniSidekiq.retry_key)

      member = MiniSidekiq.redis.zrange(MiniSidekiq.retry_key, 0, -1, with_scores: true).first
      retried_payload = JSON.parse(member.first)
      assert_equal 1, retried_payload["attempts"]
      assert_equal "RuntimeError", retried_payload["error_class"]
      assert_equal "boom", retried_payload["error_message"]
      assert_in_delta before + BACKOFF_SECONDS, member.last, 1.0
    end

    test "third consecutive failure buries to dead list" do
      payload = { "jid" => "j", "class" => "WorkerTestFailingJob", "args" => [],
                  "queue" => "default", "attempts" => 2 }
      Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))

      assert_equal 0, MiniSidekiq.redis.zcard(MiniSidekiq.retry_key)
      assert_equal 1, MiniSidekiq.redis.llen(MiniSidekiq.dead_key)

      dead = JSON.parse(MiniSidekiq.redis.lrange(MiniSidekiq.dead_key, 0, -1).first)
      assert_equal 3, dead["attempts"]
      assert_equal "RuntimeError", dead["error_class"]
    end

    test "missing job class buries directly to dead" do
      payload = { "jid" => "j", "class" => "DoesNotExistJob", "args" => [],
                  "queue" => "default", "attempts" => 0 }
      Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))

      assert_equal 0, MiniSidekiq.redis.zcard(MiniSidekiq.retry_key)
      assert_equal 1, MiniSidekiq.redis.llen(MiniSidekiq.dead_key)
      dead = JSON.parse(MiniSidekiq.redis.lrange(MiniSidekiq.dead_key, 0, -1).first)
      assert_equal "NameError", dead["error_class"]
    end

    test "corrupt JSON buries the raw payload" do
      Worker.new(concurrency: 1).send(:execute, "{not json")

      assert_equal 0, MiniSidekiq.redis.zcard(MiniSidekiq.retry_key)
      assert_equal 1, MiniSidekiq.redis.llen(MiniSidekiq.dead_key)
      dead = JSON.parse(MiniSidekiq.redis.lrange(MiniSidekiq.dead_key, 0, -1).first)
      assert_equal "<corrupt>", dead["class"]
    end

    test "error_handler is invoked on failure" do
      captured = []
      MiniSidekiq.error_handler = ->(e, ctx) { captured << [e.class, ctx["class"]] }

      payload = { "jid" => "j", "class" => "WorkerTestFailingJob", "args" => [],
                  "queue" => "default", "attempts" => 0 }
      Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))

      assert_equal 1, captured.size
      assert_equal RuntimeError, captured.first.first
      assert_equal "WorkerTestFailingJob", captured.first.last
    end
  end
end
