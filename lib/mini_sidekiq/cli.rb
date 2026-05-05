module MiniSidekiq
  # Operational + verification Cli for mini-sidekiq.
  #
  # Subcommands:
  #   verify [--db N]              run feature checks against a verification DB
  #   enqueue [class] [args...]    enqueue an immediate job (default: SampleJob)
  #   enqueue-in <secs> [class] [args...]  enqueue a delayed job
  #   stats                        show queue / schedule / retry / dead counts
  #   peek <key>                   inspect entries in a list or zset
  #   flush                        delete all mini_sidekiq:* keys (asks first)
  #   worker [--concurrency N]     run the worker process
  #   demo                         run the end-to-end demo script
  #   help                         show this help
  class Cli
    KEYS = [
      "mini_sidekiq:queue:high",
      "mini_sidekiq:queue:default",
      "mini_sidekiq:queue:low",
      "mini_sidekiq:schedule",
      "mini_sidekiq:retry",
      "mini_sidekiq:dead"
    ].freeze

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def run
      cmd = @argv.shift
      case cmd
      when "verify"     then Verify.new(@argv, @out, @err).run
      when "enqueue"    then enqueue_immediate
      when "enqueue-in" then enqueue_delayed
      when "stats"      then stats
      when "peek"       then peek
      when "flush"      then flush
      when "worker"     then run_worker
      when "demo"       then run_demo
      when "help", "--help", "-h", nil then print_help
      else
        @err.puts "unknown command: #{cmd}"
        print_help
        exit 1
      end
    end

    private

    def enqueue_immediate
      class_name, *args = @argv
      class_name ||= "MiniSidekiq::Cli::SampleJob"
      ensure_class_loaded(class_name)
      payload = Client.push(class_name: class_name, args: args, queue: env_queue || DEFAULT_QUEUE)
      @out.puts "Enqueued #{class_name} to queue:#{payload['queue']} (jid=#{payload['jid']})"
    end

    def enqueue_delayed
      seconds = @argv.shift
      unless seconds && seconds.match?(/\A\d+(\.\d+)?\z/)
        @err.puts "usage: enqueue-in <seconds> [class] [args...]"
        exit 1
      end
      class_name, *args = @argv
      class_name ||= "MiniSidekiq::Cli::SampleJob"
      ensure_class_loaded(class_name)
      run_at = Time.now.to_f + seconds.to_f
      payload = Client.push(
        class_name: class_name,
        args: args,
        queue: env_queue || DEFAULT_QUEUE,
        run_at: run_at
      )
      @out.puts "Scheduled #{class_name} for #{Time.at(run_at)} (jid=#{payload['jid']})"
    end

    def stats
      r = MiniSidekiq.redis
      @out.puts "Mini-Sidekiq state at #{Time.now} (#{MiniSidekiq.redis_url})"
      @out.puts ""
      QUEUES.each do |q|
        count = r.llen(MiniSidekiq.queue_key(q))
        @out.puts format("  queue:%-8s  %d", q, count)
      end
      @out.puts format("  %-14s  %d", "schedule", r.zcard(MiniSidekiq.schedule_key))
      @out.puts format("  %-14s  %d", "retry", r.zcard(MiniSidekiq.retry_key))
      @out.puts format("  %-14s  %d", "dead", r.llen(MiniSidekiq.dead_key))
    end

    def peek
      key = @argv.shift
      unless key
        @err.puts "usage: peek <key>"
        @err.puts "  example: peek queue:default | peek schedule | peek retry | peek dead"
        exit 1
      end
      key = "mini_sidekiq:#{key}" unless key.start_with?("mini_sidekiq:")
      r = MiniSidekiq.redis
      type = r.type(key)
      case type
      when "list"
        items = r.lrange(key, 0, -1)
        @out.puts "#{key} (list, #{items.size} entries):"
        items.each_with_index { |json, i| @out.puts "  [#{i}] #{json}" }
      when "zset"
        items = r.zrange(key, 0, -1, with_scores: true)
        @out.puts "#{key} (zset, #{items.size} entries):"
        items.each_with_index { |(json, score), i| @out.puts "  [#{i}] score=#{Time.at(score)} #{json}" }
      when "none"
        @out.puts "#{key} does not exist (or is empty)"
      else
        @out.puts "#{key} is a #{type}, peek is only implemented for lists and zsets"
      end
    end

    def flush
      r = MiniSidekiq.redis
      total = KEYS.sum { |k| r.exists?(k) ? 1 : 0 }
      if total.zero?
        @out.puts "No mini_sidekiq:* keys present, nothing to flush."
        return
      end
      @out.print "About to delete #{total} mini_sidekiq:* key(s) on #{MiniSidekiq.redis_url}. Continue? [y/N] "
      answer = $stdin.gets&.strip&.downcase
      if answer == "y" || answer == "yes"
        KEYS.each { |k| r.del(k) }
        @out.puts "Deleted."
      else
        @out.puts "Aborted."
      end
    end

    def run_worker
      concurrency = nil
      while (flag = @argv.shift)
        case flag
        when "--concurrency", "-c" then concurrency = @argv.shift.to_i
        else
          @err.puts "unknown flag: #{flag}"
          exit 1
        end
      end
      worker = concurrency ? Worker.new(concurrency: concurrency) : Worker.new
      worker.run
    end

    def run_demo
      load File.expand_path("../../script/mini_sidekiq_demo.rb", __dir__)
    end

    def ensure_class_loaded(class_name)
      Object.const_get(class_name)
    rescue NameError
      load_sample_job if class_name == "MiniSidekiq::Cli::SampleJob"
    end

    def load_sample_job
      MiniSidekiq::Cli.const_set(:SampleJob, Class.new do
        include MiniSidekiq::Job
        def perform(*args)
          puts "[SampleJob] ran with #{args.inspect} at #{Time.now}"
        end
      end) unless MiniSidekiq::Cli.const_defined?(:SampleJob)
    end

    def env_queue
      ENV["MINI_SIDEKIQ_QUEUE"]
    end

    def print_help
      @out.puts <<~HELP
        Mini-Sidekiq Cli

        USAGE
          bin/mini_sidekiq_cli <command> [args]

        COMMANDS
          verify [--db N]                Run feature checks against verification DB N (default 15)
          enqueue [class] [args...]      Enqueue an immediate job (default class: SampleJob)
          enqueue-in <secs> [class] [a]  Enqueue a delayed job
          stats                          Show queue / schedule / retry / dead counts
          peek <key>                     Inspect entries in queue:high|default|low|schedule|retry|dead
          flush                          Delete all mini_sidekiq:* keys (with confirmation)
          worker [--concurrency N]       Run the worker process (alias for bin/mini_sidekiq)
          demo                           Run the end-to-end demo
          help                           Show this help

        ENV
          MINI_SIDEKIQ_REDIS_URL         Redis URL (default: redis://localhost:6379/0)
          MINI_SIDEKIQ_QUEUE             Default queue for enqueue (default: "default")

        EXAMPLES
          bin/mini_sidekiq_cli verify
          bin/mini_sidekiq_cli enqueue
          MINI_SIDEKIQ_QUEUE=high bin/mini_sidekiq_cli enqueue MyJob 42
          bin/mini_sidekiq_cli enqueue-in 5 MyJob hello
          bin/mini_sidekiq_cli stats
          bin/mini_sidekiq_cli peek queue:default
      HELP
    end

    # Verification subcommand: runs each feature as an isolated check against a
    # dedicated Redis DB (default DB 15). Prints PASS/FAIL per check and exits
    # non-zero if anything fails.
    class Verify
      Check = Struct.new(:name, :status, :detail)

      def initialize(argv, out, err)
        @argv = argv.dup
        @out = out
        @err = err
        @db = 15
        @results = []
        parse_flags
      end

      def run
        prepare_redis
        execute_all
        report
        exit(@results.any? { |r| r.status != :pass } ? 1 : 0)
      end

      private

      def parse_flags
        while (flag = @argv.shift)
          case flag
          when "--db" then @db = @argv.shift.to_i
          else
            @err.puts "unknown flag: #{flag}"
            exit 1
          end
        end
      end

      def prepare_redis
        url = "redis://#{redis_host}:#{redis_port}/#{@db}"
        MiniSidekiq.redis_url = url
        Thread.current[:mini_sidekiq_redis] = nil
        MiniSidekiq.redis.flushdb
        MiniSidekiq::Cron.reset!
        @out.puts "Running verification against #{url}"
        @out.puts ""
      end

      def redis_host
        URI.parse(ENV["MINI_SIDEKIQ_REDIS_URL"] || ENV["REDIS_URL"] || "redis://localhost:6379").host || "localhost"
      end

      def redis_port
        URI.parse(ENV["MINI_SIDEKIQ_REDIS_URL"] || ENV["REDIS_URL"] || "redis://localhost:6379").port || 6379
      end

      def execute_all
        check("Redis connectivity")              { check_redis_connectivity }
        check("Client.push to default queue")    { check_client_push_default }
        check("Priority queue pop ordering")     { check_priority_pop }
        check("perform_in lands in schedule")    { check_perform_in_schedule }
        check("perform_at uses exact score")     { check_perform_at_score }
        check("Scheduler.drain promotes due")    { check_scheduler_drain }
        check("Failing job → retry zset")        { check_retry_first_failure }
        check("3rd failure → dead list")         { check_retry_exhausted }
        check("Missing class → dead list")       { check_missing_class }
        check("Corrupt payload → dead list")     { check_corrupt_payload }
        check("error_handler hook is called")    { check_error_handler_hook }
        check("Cron.register parses + stores")   { check_cron_register }
        check("Cron.tick fires when due")        { check_cron_tick }
        check("End-to-end worker run")           { check_end_to_end }
      end

      def check(name)
        flush_state
        yield
        @results << Check.new(name, :pass, nil)
        @out.puts format("  [%2d] %-40s ✓ PASS", @results.size, name)
      rescue => e
        @results << Check.new(name, :fail, "#{e.class}: #{e.message}")
        @out.puts format("  [%2d] %-40s ✗ FAIL  (%s)", @results.size, name, e.message)
      end

      def flush_state
        MiniSidekiq.redis.flushdb
        MiniSidekiq::Cron.reset!
        MiniSidekiq.error_handler = ->(*) {}
      end

      def report
        passed = @results.count { |r| r.status == :pass }
        total  = @results.size
        @out.puts ""
        if passed == total
          @out.puts "✓ ALL CHECKS PASSED (#{passed}/#{total})"
        else
          @out.puts "✗ #{total - passed} check(s) failed (#{passed}/#{total} passed)"
          @results.each do |r|
            next unless r.status == :fail
            @out.puts "    - #{r.name}: #{r.detail}"
          end
        end
      end

      # ---- individual checks ----

      def check_redis_connectivity
        MiniSidekiq.redis.set("mini_sidekiq:probe", "ok")
        result = MiniSidekiq.redis.get("mini_sidekiq:probe")
        MiniSidekiq.redis.del("mini_sidekiq:probe")
        assert(result == "ok", "expected 'ok', got #{result.inspect}")
      end

      def check_client_push_default
        Client.push(class_name: "Probe", args: [1])
        json = MiniSidekiq.redis.lrange(MiniSidekiq.queue_key("default"), 0, -1).first
        assert(json, "no entry pushed to queue:default")
        payload = JSON.parse(json)
        assert(payload["class"] == "Probe", "wrong class: #{payload['class']}")
        assert(payload["args"] == [1], "wrong args: #{payload['args']}")
        assert(payload["queue"] == "default", "wrong queue: #{payload['queue']}")
      end

      def check_priority_pop
        Client.push(class_name: "Probe", args: ["L"], queue: "low")
        Client.push(class_name: "Probe", args: ["H"], queue: "high")
        Client.push(class_name: "Probe", args: ["D"], queue: "default")

        worker = Worker.new(concurrency: 1)
        keys   = QUEUES.map { |q| MiniSidekiq.queue_key(q) }
        order  = 3.times.map { JSON.parse(worker.send(:pop_next, keys))["queue"] }

        assert(order == %w[high default low], "got #{order.inspect}, expected [high, default, low]")
      end

      def check_perform_in_schedule
        klass = define_probe_job
        before = Time.now.to_f
        klass.perform_in(60, "x")
        zsize = MiniSidekiq.redis.zcard(MiniSidekiq.schedule_key)
        assert(zsize == 1, "expected 1 entry in schedule, got #{zsize}")
        score = MiniSidekiq.redis.zrange(MiniSidekiq.schedule_key, 0, -1, with_scores: true).first.last
        delta = score - before
        assert(delta > 59 && delta < 61, "score offset wrong: #{delta}s")
      end

      def check_perform_at_score
        klass = define_probe_job
        target = Time.now + 120
        klass.perform_at(target, "x")
        score = MiniSidekiq.redis.zrange(MiniSidekiq.schedule_key, 0, -1, with_scores: true).first.last
        assert((score - target.to_f).abs < 0.01, "expected #{target.to_f}, got #{score}")
      end

      def check_scheduler_drain
        # past-due entry should be promoted
        payload = { "class" => "Probe", "args" => [], "queue" => "high", "attempts" => 0, "jid" => "x" }
        json = JSON.dump(payload)
        MiniSidekiq.redis.zadd(MiniSidekiq.schedule_key, Time.now.to_f - 1, json)
        # future entry should NOT be
        future = JSON.dump(payload.merge("jid" => "y"))
        MiniSidekiq.redis.zadd(MiniSidekiq.schedule_key, Time.now.to_f + 60, future)

        Scheduler.new(StubFlag.new).send(:drain, MiniSidekiq.schedule_key, Time.now.to_f)

        assert(MiniSidekiq.redis.llen(MiniSidekiq.queue_key("high")) == 1, "due entry not promoted")
        assert(MiniSidekiq.redis.zcard(MiniSidekiq.schedule_key) == 1, "future entry was incorrectly promoted")
      end

      def check_retry_first_failure
        klass = define_failing_job
        payload = { "jid" => "j", "class" => klass.name, "args" => [], "queue" => "default", "attempts" => 0 }
        Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))

        assert(MiniSidekiq.redis.zcard(MiniSidekiq.retry_key) == 1, "expected 1 entry in retry zset")
        member = MiniSidekiq.redis.zrange(MiniSidekiq.retry_key, 0, -1, with_scores: true).first
        retried = JSON.parse(member.first)
        assert(retried["attempts"] == 1, "expected attempts=1, got #{retried['attempts']}")
        assert((member.last - (Time.now.to_f + BACKOFF_SECONDS)).abs < 2, "retry score wrong")
      end

      def check_retry_exhausted
        klass = define_failing_job
        payload = { "jid" => "j", "class" => klass.name, "args" => [], "queue" => "default", "attempts" => 2 }
        Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))

        assert(MiniSidekiq.redis.llen(MiniSidekiq.dead_key) == 1, "expected 1 entry in dead list")
        dead = JSON.parse(MiniSidekiq.redis.lrange(MiniSidekiq.dead_key, 0, -1).first)
        assert(dead["attempts"] == 3, "expected attempts=3, got #{dead['attempts']}")
      end

      def check_missing_class
        payload = { "jid" => "j", "class" => "DoesNotExistAnywhere", "args" => [], "queue" => "default", "attempts" => 0 }
        Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))
        assert(MiniSidekiq.redis.llen(MiniSidekiq.dead_key) == 1, "missing class did not land in dead")
        assert(MiniSidekiq.redis.zcard(MiniSidekiq.retry_key) == 0, "missing class was incorrectly retried")
      end

      def check_corrupt_payload
        Worker.new(concurrency: 1).send(:execute, "{not valid json")
        assert(MiniSidekiq.redis.llen(MiniSidekiq.dead_key) == 1, "corrupt payload did not land in dead")
      end

      def check_error_handler_hook
        klass = define_failing_job
        captured = []
        MiniSidekiq.error_handler = ->(e, ctx) { captured << [e.class, ctx["class"]] }
        payload = { "jid" => "j", "class" => klass.name, "args" => [], "queue" => "default", "attempts" => 0 }
        Worker.new(concurrency: 1).send(:execute, JSON.dump(payload))
        assert(captured.size == 1, "error_handler called #{captured.size} times, expected 1")
        assert(captured.first.first == RuntimeError, "wrong exception class: #{captured.first.first}")
      end

      def check_cron_register
        klass = define_probe_job
        Cron.register("hourly", "0 * * * *", klass)
        assert(Cron.entries.size == 1, "expected 1 entry, got #{Cron.entries.size}")
        assert(Cron.entries.first.name == "hourly", "wrong name")
      end

      def check_cron_tick
        klass = define_probe_job
        Cron.register("every-min", "* * * * *", klass, queue: :default)
        Cron.entries.first.next_fire_at = Time.now.to_f - 1
        Cron.new(StubFlag.new, entries: Cron.entries).tick
        assert(MiniSidekiq.redis.llen(MiniSidekiq.queue_key("default")) == 1, "cron did not enqueue")
        assert(Cron.entries.first.next_fire_at > Time.now.to_f, "next_fire_at not recomputed")
      end

      def check_end_to_end
        # Spawn the full worker for ~1.5s and confirm an enqueued job actually executes.
        sentinel_path = "/tmp/mini_sidekiq_verify_sentinel_#{Process.pid}"
        File.delete(sentinel_path) if File.exist?(sentinel_path)
        klass = Class.new do
          include MiniSidekiq::Job
          @@path = sentinel_path
          define_method(:perform) { |path| File.write(path, "ran at #{Time.now}") }
        end
        Object.const_set(:VerifyEndToEndJob, klass) unless Object.const_defined?(:VerifyEndToEndJob)
        VerifyEndToEndJob.perform_async(sentinel_path)

        worker = Worker.new(concurrency: 1)
        thread = Thread.new { worker.run }
        sleep 1.5
        worker.instance_variable_get(:@shutdown).set!
        thread.join(8)

        assert(File.exist?(sentinel_path), "sentinel file was not written — job did not execute")
        File.delete(sentinel_path)
      end

      def define_probe_job
        @probe_job_count ||= 0
        @probe_job_count += 1
        name = "VerifyProbeJob#{@probe_job_count}"
        klass = Class.new do
          include MiniSidekiq::Job
          def perform(*); end
        end
        Object.const_set(name, klass) unless Object.const_defined?(name)
        Object.const_get(name)
      end

      def define_failing_job
        unless Object.const_defined?(:VerifyFailingJob)
          klass = Class.new do
            include MiniSidekiq::Job
            def perform(*); raise "boom"; end
          end
          Object.const_set(:VerifyFailingJob, klass)
        end
        Object.const_get(:VerifyFailingJob)
      end

      def assert(condition, message)
        raise message unless condition
      end

      class StubFlag
        def true?; false; end
        def set!; end
      end
    end
  end
end
