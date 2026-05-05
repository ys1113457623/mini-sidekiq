# Mini-Sidekiq

A miniature Sidekiq-style background-job runner built as a take-home exercise. Redis-backed, Ruby. Three priority queues, scheduled jobs, synchronous in-process execution, cron, retries, dead set, graceful shutdown.

> **For the reviewer:** start with this file. It covers (a) how to run the app, (b) how to run the tests, (c) where the code lives and the order to read it, and (d) the design decisions and trade-offs. The full design spec is at [`docs/superpowers/specs/2026-05-05-mini-sidekiq-design.md`](docs/superpowers/specs/2026-05-05-mini-sidekiq-design.md).

## Run it (Docker — the path I recommend for review)

This repository already has a `docker-compose.yml` at the root with Postgres, Redis, and the Rails containers wired up. **Two commands** is the fastest way to confirm everything works.

### 1. Bring the stack up

```sh
docker compose up -d
```

This builds the dev image on first run (a few minutes) and starts `postgres`, `redis`, `web`, `vite`, and `worker` containers. Wait for the healthchecks; the `redis` container is what mini-sidekiq talks to.

### 2. Run the verification CLI

```sh
docker compose exec web bin/mini_sidekiq_cli verify
```

This runs **15 isolated feature checks** against a verification Redis DB and prints PASS/FAIL per feature. Sample output:

```
Running verification against redis://redis:6379/15

  [ 1] Redis connectivity                       ✓ PASS
  [ 2] Client.push to default queue             ✓ PASS
  [ 3] Priority queue pop ordering              ✓ PASS
  [ 4] perform_in lands in schedule             ✓ PASS
  [ 5] perform_at uses exact score              ✓ PASS
  [ 6] perform_inline runs in-process           ✓ PASS
  [ 7] Scheduler.drain promotes due             ✓ PASS
  [ 8] Failing job → retry zset                 ✓ PASS
  [ 9] 3rd failure → dead list                  ✓ PASS
  [10] Missing class → dead list                ✓ PASS
  [11] Corrupt payload → dead list              ✓ PASS
  [12] error_handler hook is called             ✓ PASS
  [13] Cron.register parses + stores            ✓ PASS
  [14] Cron.tick fires when due                 ✓ PASS
  [15] End-to-end worker run                    ✓ PASS

✓ ALL CHECKS PASSED (15/15)
```

The CLI exits non-zero if any check fails, so it's CI-friendly. Each check is described in the [Verification checks](#verification-checks) table below.

### Optional: also run the unit test suite

The 21-test minitest suite covers the same components from a different angle (interface contracts via stubbed inputs, isolated unit semantics):

```sh
docker compose exec web bundle exec ruby -Itest test/mini_sidekiq/run.rb
```

Expected:

```
21 runs, 54 assertions, 0 failures, 0 errors, 0 skips
```

The tests bypass `rails/test_help` so they don't need the Postgres test schema — Redis is the only dependency.

### Optional: visually watch a live demo

```sh
docker compose exec web bin/mini_sidekiq_cli demo
```

This is a single-command demo (~12 s wall-clock) that exercises every feature in real time and prints what each thread does, then shows the final Redis state. Sample output:

```
=== Mini-Sidekiq end-to-end demo ===

Enqueuing five jobs:
  - HighPriorityJob "priority-A"           [queue:high, immediate]
  - DemoJob         "immediate"            [queue:default, immediate]
  - DemoJob         "+1s delayed"          [queue:default, perform_in(1)]
  - DemoJob         "+2s delayed"          [queue:default, perform_in(2)]
  - FlakyJob        "will fail then retry" [queue:default, immediate, raises]

Starting worker (concurrency=1, so priority-order is visible) for 6 seconds...
------------------------------------------------------------------
[mini_sidekiq] starting (concurrency=1)
  ▶ HIGH    ▶ priority-A           at 21:20:24.744       ← high pulled before default
  ▶ default ▶ immediate            at 21:20:24.745
  ▶ flaky   ▶ will fail then retry at 21:20:24.745 (raising)
  ▶ default ▶ +1s delayed          at 21:20:25.790       ← scheduler promoted at +1s
  ▶ default ▶ +2s delayed          at 21:20:26.832       ← scheduler promoted at +2s
  ▶ flaky   ▶ will fail then retry at 21:20:29.844 (raising)  ← retry attempt #2 at +5s
------------------------------------------------------------------
Sending SIGINT for graceful shutdown...
[mini_sidekiq] shutdown complete

=== Final Redis state ===
  queue:high       0
  queue:default    0
  queue:low        0
  schedule         0
  retry            1
  dead             0

FlakyJob is in the retry zset, scheduled for ... (attempts=2, last error: RuntimeError: intentional failure)
```

What the demo proves:

| Feature | Evidence in the output |
|---|---|
| Three priority queues, high beats default | `HIGH ▶ priority-A` runs before `default ▶ immediate` even though both were enqueued ready |
| `perform_in(seconds)` | `+1s delayed` runs at t≈1.0s, `+2s delayed` at t≈2.0s |
| Retries with backoff | FlakyJob runs at t=0 and again at t=+5s (one `BACKOFF_SECONDS × attempts` later); 3rd attempt would land at +10s but the demo stops first, so the job is left in the retry zset for the next worker run |
| Graceful shutdown | "shutdown complete" log line, queues fully drained except the in-flight retry |

(Cron firing is not in the live demo because the cron poller's interval is 5 s by default — running long enough to observe a real fire would slow the demo down. Cron behavior is verified in [`test/mini_sidekiq/cron_test.rb`](test/mini_sidekiq/cron_test.rb).)

### Verification checks

Each `verify` check is small and isolated — it flushes the verification DB before running, exercises one specific behavior, and asserts the resulting Redis or in-memory state.

| # | Check | What it proves |
|---|---|---|
| 1 | Redis connectivity | `MiniSidekiq.redis` can `SET`/`GET`/`DEL` |
| 2 | `Client.push` to default queue | Enqueue produces a JSON payload with the right `class`/`args`/`queue` fields and lands in `queue:default` |
| 3 | Priority queue pop ordering | Enqueue one to each of `high/default/low`; `Worker#pop_next` returns them in `[high, default, low]` order |
| 4 | `perform_in` lands in schedule | `perform_in(60)` writes to `schedule` zset with score ≈ now + 60 |
| 5 | `perform_at` exact score | `perform_at(time)` writes to `schedule` with score == `time.to_f` |
| 6 | `perform_inline` runs in-process | Synchronous execution path: `perform_inline` runs the job in the caller's thread, returns the result, and writes nothing to Redis |
| 7 | Scheduler drain promotes due | Past-due entries get moved into queue lists; future entries stay put |
| 8 | Failing job → retry zset | `attempts: 0` failing payload lands in `retry` with `attempts: 1` and score ≈ now + `BACKOFF_SECONDS` |
| 9 | 3rd failure → dead list | `attempts: 2` failing payload lands in `dead` with `attempts: 3` |
| 10 | Missing class → dead list | Payload referencing a non-existent class bypasses retry, goes straight to `dead` |
| 11 | Corrupt payload → dead list | Non-JSON input is captured into `dead` with class `<corrupt>` |
| 12 | `error_handler` hook is called | Custom error handler proc receives the exception and payload context |
| 13 | `Cron.register` parses + stores | A valid cron expression is parsed by fugit and added to the registry |
| 14 | `Cron.tick` fires when due | Forcing `next_fire_at` into the past causes one enqueue and recomputes `next_fire_at` |
| 15 | End-to-end worker run | Spawns the full worker (executor + scheduler + cron threads) for ~1.5 s and confirms an enqueued job actually runs (writes a sentinel file) |

### CLI reference

The CLI also exposes operational subcommands so the examiner can drive the system manually:

```sh
docker compose exec web bin/mini_sidekiq_cli help

# inspect state
docker compose exec web bin/mini_sidekiq_cli stats
docker compose exec web bin/mini_sidekiq_cli peek queue:default
docker compose exec web bin/mini_sidekiq_cli peek schedule

# enqueue
docker compose exec web bin/mini_sidekiq_cli enqueue                       # SampleJob → default
docker compose exec web bin/mini_sidekiq_cli enqueue MyJob 42 hello        # MyJob → default
docker compose exec -e MINI_SIDEKIQ_QUEUE=high web bin/mini_sidekiq_cli enqueue MyJob   # → high
docker compose exec web bin/mini_sidekiq_cli enqueue-in 30 MyJob something # delayed 30 s

# clean up
docker compose exec web bin/mini_sidekiq_cli flush                         # confirms first

# run the worker
docker compose exec web bin/mini_sidekiq_cli worker --concurrency 3
# (equivalent to: docker compose exec web bin/mini_sidekiq)
```

If you want to manually enqueue from a Rails console and watch the worker, run two terminals:

```sh
# terminal 1 — worker
docker compose exec web bin/mini_sidekiq

# terminal 2 — Rails console
docker compose exec web bin/rails console
```

```ruby
class HelloJob
  include MiniSidekiq::Job
  mini_sidekiq_options queue: :default
  def perform(name) = puts "[HelloJob] #{name} at #{Time.now}"
end

HelloJob.perform_async("immediate")
HelloJob.perform_in(5, "in five seconds")
HelloJob.perform_at(Time.now + 30, "in thirty")

MiniSidekiq::Cron.register("every-minute", "* * * * *", HelloJob, queue: :high)
```

Stop the worker with `Ctrl-C` — shutdown is clean (no stack trace).

> **Why a separate worker process when there's already a `worker` container running Sidekiq?**
> The compose stack's `worker` runs *real* Sidekiq for the host Rails app. Mini-Sidekiq is a separate, drop-in implementation; running `bin/mini_sidekiq` from the `web` container starts an additional independent worker process that uses the same Redis but its own keyspace (`mini_sidekiq:*`).

## Run it (without Docker)

If you're running the host project natively (Postgres + Redis on your machine), drop the `docker compose exec web` prefix:

```sh
bundle install
bin/mini_sidekiq_cli verify                                   # 14-check verification CLI
bundle exec ruby -Itest test/mini_sidekiq/run.rb              # 21-test minitest suite
bin/mini_sidekiq_cli demo                                     # end-to-end live demo
bin/mini_sidekiq_cli worker                                   # long-running worker
```

The CLI honors `MINI_SIDEKIQ_REDIS_URL` (default `redis://localhost:6379/0`) for the operational subcommands; `verify` uses its own DB (default 15, override with `--db N`) so it never touches production traffic.

The mini-sidekiq tests do not need Postgres at all — only a reachable Redis.

## Prerequisites

| | |
|---|---|
| Ruby | 3.3.x (project uses 3.3.10 via `.ruby-version`) — pre-installed in the dev container |
| Redis | any modern Redis (5.0+). Provided by the `redis` service in `docker-compose.yml`. The executor falls back to polling `RPOP`; see [Design notes](#design-notes-and-trade-offs). |
| Postgres | **not required for mini-sidekiq.** The wider Rails app uses Postgres, but mini-sidekiq tests bypass `rails/test_help` so they need only Redis. |

## Code map (read in this order)

| | File | What to look for |
|---|---|---|
| 1 | [`lib/mini_sidekiq.rb`](lib/mini_sidekiq.rb) | Top-level configuration, Redis-key helpers, default error handler, retry/dead-list constants. The contract for the rest of the system. |
| 2 | [`lib/mini_sidekiq/client.rb`](lib/mini_sidekiq/client.rb) | The single writer to Redis on the enqueue path. Decides between `LPUSH queue:<name>` (immediate) and `ZADD schedule` (timed). |
| 3 | [`lib/mini_sidekiq/job.rb`](lib/mini_sidekiq/job.rb) | `include MiniSidekiq::Job` mixin. Adds `perform_async`, `perform_in`, `perform_at` plus a `mini_sidekiq_options queue: …` macro. Zero Redis knowledge — calls `Client.push`. |
| 4 | [`lib/mini_sidekiq/scheduler.rb`](lib/mini_sidekiq/scheduler.rb) | Polls `schedule` and `retry` sorted sets every 1 s, atomically moves due entries into their queue lists with `MULTI`/`EXEC`. |
| 5 | [`lib/mini_sidekiq/cron.rb`](lib/mini_sidekiq/cron.rb) | Cron registry + 5 s poller. Uses `fugit` for cron parsing. Cron entries live in process memory; firing means enqueueing through `Client.push` and recomputing `next_fire_at`. |
| 6 | [`lib/mini_sidekiq/worker.rb`](lib/mini_sidekiq/worker.rb) | Thread orchestration (executor pool + scheduler + cron), signal handling for graceful shutdown, the rescue chain that decides retry vs. dead. |
| 7 | [`lib/mini_sidekiq/cli.rb`](lib/mini_sidekiq/cli.rb) | The `verify` / `enqueue` / `stats` / `peek` / `flush` / `worker` / `demo` CLI. Self-contained: each `verify` check exercises one feature against an isolated Redis DB. |
| 8 | [`bin/mini_sidekiq`](bin/mini_sidekiq) | Executable entrypoint for the worker process — boots Rails (so `lib/` autoloads + initializers run for cron registrations) and calls `Worker.new.run`. |
| 9 | [`bin/mini_sidekiq_cli`](bin/mini_sidekiq_cli) | Executable entrypoint for the CLI (delegates to `MiniSidekiq::Cli`). |

Tests mirror the source files at [`test/mini_sidekiq/`](test/mini_sidekiq/). They focus on contracts (what each component promises), not on Ruby/Redis internals.

## Architecture

Single Ruby process. Three thread roles:

```
                ┌─ Executor #1 ──┐
                ├─ Executor #2 ──┤   walk [queue:high, queue:default, queue:low]
   Worker  ─────┼─ Executor #3 ──┤   call RPOP, first non-nil wins
                └─ Executor #N ──┘   sleep 100 ms when all empty

                ├─ Scheduler ────┐   every 1 s, ZRANGEBYSCORE schedule + retry,
                │                │   MULTI/EXEC move into queue list
                └─ Cron poller ──┘   every 5 s, fugit.next_time → enqueue + recompute
```

Cron is the simplest layer: it just enqueues normal jobs. Once a cron-triggered job is in a queue, it is indistinguishable from any other. **There is one execution path** — pop from a queue, run, on failure decide retry vs. dead.

### Redis keys (six total, that's all the durable state)

```
mini_sidekiq:queue:high           List   (LPUSH on enqueue, RPOP on consume)
mini_sidekiq:queue:default        List
mini_sidekiq:queue:low            List
mini_sidekiq:schedule             ZSet   (score = run-at unix timestamp)
mini_sidekiq:retry                ZSet   (score = retry-at unix timestamp)
mini_sidekiq:dead                 List   (capped at 1000 via LTRIM)
```

### Job payload (one JSON shape across every key)

```json
{
  "jid": "a1b2c3d4e5f6",
  "class": "EmailJob",
  "args": ["user@example.com", "welcome"],
  "queue": "default",
  "enqueued_at": 1730830000.123,
  "attempts": 0,
  "error_class": null,
  "error_message": null
}
```

## Design notes and trade-offs

These are the decisions worth examining; each is also covered in the [full spec](docs/superpowers/specs/2026-05-05-mini-sidekiq-design.md).

**Priority queues = three separate Redis lists, not one list with a priority field.**
Pulling from priority order is then trivial: walk `[high, default, low]` and pop the first non-empty. No sorting, no scanning.

**Scheduled and retry jobs share one mechanism: a sorted set keyed by run-at timestamp.**
The scheduler thread treats them identically. `ZRANGEBYSCORE -inf <now>` returns exactly the due entries in O(log N). `MULTI`/`EXEC` makes the move atomic so a job cannot land in a queue twice if multiple scheduler threads were ever introduced.

**Cron is a thin layer that emits regular jobs.**
The cron poller computes the next-fire timestamp via `fugit`, and when `now >= next_fire_at` it calls `Client.push` (a normal enqueue) and recomputes `next_fire_at`. There is no special "cron job" execution path. This keeps the system to one execution model.

**Retries: 3 attempts max, 5 s × attempt fixed backoff, then bury.**
Hardcoded constants in `lib/mini_sidekiq.rb` rather than per-job options — simpler. Permanent failures (corrupt JSON, missing job class) skip the retry zset and go straight to the dead list, since retrying cannot fix them.

**Configurable error handler.**
`MiniSidekiq.error_handler = ->(e, ctx) { ... }` is invoked on every caught exception (job failure, parse error, missing class) before the retry/dead decision. The default logs to `MiniSidekiq.logger`. The intended production wiring is `Sentry.capture_exception(e, extra: ctx)`; the placeholder is in place but Sentry itself is not integrated, per the spec.

**`Client.push` is the single Redis writer on the enqueue path.**
Every other component that needs to enqueue (cron firing, retry-coming-back-to-queue via the scheduler) goes through `Client.push`. One place to change the wire format.

**Polling `RPOP` instead of `BRPOP` for the executor.**
The original design called for `BRPOP key1 key2 key3 timeout` (priority by argument order, no polling). I switched to non-blocking `RPOP` + 100 ms sleep on empty because the local Redis (Homebrew, reports as 8.6.2) did not honor the `BRPOP` per-command timeout on empty lists, which made graceful shutdown wait the full socket-read grace period. With a real Redis 7.x server, `BRPOP` is the better choice — the change is one method ([`Worker#pop_next`](lib/mini_sidekiq/worker.rb)).

**Worker process boots the host Rails environment.**
[`bin/mini_sidekiq`](bin/mini_sidekiq) calls `require "config/environment"` so `lib/` autoloading is wired up and any `MiniSidekiq::Cron.register` calls placed in `config/initializers/*.rb` run at boot. The library itself does not depend on Rails; it would work in any Ruby app with `require "mini_sidekiq"` and `require "mini_sidekiq/<file>"` calls.

## Known limitations

- **Crash-during-execute loses the job.** A worker `SIGKILL` between the `RPOP` and the `perform` call drops the job. Sidekiq <7 has the same property. The proper fix is a "processing" set + reaper thread; out of scope for the time budget.
- **No web UI.** Inspect state via `redis-cli`: `LRANGE mini_sidekiq:queue:default 0 -1`, `ZRANGE mini_sidekiq:schedule 0 -1 WITHSCORES`, `LRANGE mini_sidekiq:dead 0 -1`.
- **No middleware chain, no per-class retry policy, no idempotency tokens, no multi-process / dynamic concurrency.**
- **Cron schedules live in worker memory.** Restarting the worker re-registers them via initializers; if `next_fire_at` was in the past during downtime, the job fires once on the next tick (does not catch up missed fires). Matches Sidekiq's recurring-job behavior.

## Where to look first if you only have 5 minutes

1. [`lib/mini_sidekiq/worker.rb`](lib/mini_sidekiq/worker.rb) — read `execute_loop`, `execute`, `handle_failure`, `bury`. The retry/dead decision tree is the most interesting part of the system.
2. [`lib/mini_sidekiq/scheduler.rb`](lib/mini_sidekiq/scheduler.rb) — `drain` is 15 lines and shows the atomic move pattern.
3. [`test/mini_sidekiq/worker_test.rb`](test/mini_sidekiq/worker_test.rb) — covers retry → retry → dead progression and the permanent-failure paths.
4. [`docs/superpowers/specs/2026-05-05-mini-sidekiq-design.md`](docs/superpowers/specs/2026-05-05-mini-sidekiq-design.md) — full design rationale (about 200 lines).
