# Mini-Sidekiq — Design Spec

**Date:** 2026-05-05
**Target:** Take-home / interview practice. 60-minute build budget.
**Stack:** Ruby + Redis (running inside this Rails 8 monolith).

A miniature Sidekiq-style background job runner. Three priority queues (low/default/high), scheduled jobs (`perform_in` / `perform_at`), cron-style recurring jobs, and simple retries with a dead set.

## Goals & non-goals

**In scope**

- Three priority queues: `low`, `default`, `high` — pulled in priority order.
- Scheduled jobs via `perform_in(seconds, *args)` and `perform_at(time, *args)`.
- Recurring jobs via cron expressions (`Cron.register(name, expr, JobClass)`).
- Simple retries: max 3 attempts, fixed 5s × attempt backoff. After exhaustion, jobs land in a capped `dead` list.
- Configurable error handler (placeholder for Sentry).
- Graceful shutdown on SIGINT / SIGTERM.

**Explicit non-goals (would add later)**

- Web UI / dashboard.
- Middleware chain.
- Per-job-class retry policy.
- Multi-process workers / dynamic concurrency tuning.
- Recovery of jobs lost to mid-execution worker crashes (no "processing" set + reaper).
- Unique jobs / idempotency tokens.
- Sentry / external APM integration (placeholder hook only).

## Architecture

One Ruby process. Threads:

```
                    ┌─ Executor #1 ──┐
                    ├─ Executor #2 ──┤   pull jobs via RPOP, walking
  MiniSidekiq  ─────┼─ Executor #3 ──┤   [queue:high, queue:default, queue:low]
   worker          └─ Executor #N ──┘   in priority order (see note below)
   process
                    ├─ Scheduler ────┐   every 1s: ZRANGEBYSCORE on `schedule` and `retry`,
                    │                │   atomically move due jobs into their queue list
                    │
                    └─ Cron poller ──┘   every 5s: for each cron entry, if next-fire <= now,
                                         enqueue normally and recompute next-fire (fugit)
```

**Why this shape**

- Executors walk the priority list `[high, default, low]` and call non-blocking `RPOP` on each. First non-nil wins. When all queues are empty, sleep 100 ms and repeat.
- The original design called for `BRPOP key1 key2 key3 timeout` (Redis honors priority by argument order, no polling). I switched to polling `RPOP` because the local Redis 8.6.2 build did not honor the BRPOP per-command timeout on empty lists, which made graceful shutdown wait the full socket-read grace. With a real Redis 7.x server, `BRPOP` is the better choice — the change is one method.
- Scheduler is the only background poller of significance (1 Hz). `ZRANGEBYSCORE schedule -inf <now>` is O(log N).
- Cron is "scheduled jobs that re-register themselves." Conceptually one mechanism; cron is just a thin layer that emits regular jobs.
- All durable state lives in Redis. Worker process can be killed and restarted with no data loss (modulo the in-flight crash caveat below).

## Components

| File | Class | Responsibility |
|---|---|---|
| `lib/mini_sidekiq.rb` | `MiniSidekiq` (module) | Config (`redis_url`, `concurrency`, `error_handler`), `redis` accessor, `configure` block, constants |
| `lib/mini_sidekiq/client.rb` | `Client` | `push(class_name, args, queue:, run_at: nil)` — only writer to Redis on the enqueue path |
| `lib/mini_sidekiq/job.rb` | `Job` (mixin) | `perform_async`, `perform_in(secs)`, `perform_at(time)`, queue config via `mini_sidekiq_options queue: :default` |
| `lib/mini_sidekiq/worker.rb` | `Worker` | Boots executor pool + scheduler + cron poller; signal handling for graceful shutdown |
| `lib/mini_sidekiq/scheduler.rb` | `Scheduler` | Drains due entries from `schedule` and `retry` zsets into queue lists |
| `lib/mini_sidekiq/cron.rb` | `Cron` | Registry + poller. Uses `fugit` gem for cron expression parsing |
| `bin/mini_sidekiq` | (executable) | Loads Rails env, calls `MiniSidekiq::Worker.new.run` |

**Boundary rules**

- `Client.push` is the only writer to Redis on enqueue. Scheduler, Cron, and retry logic all funnel through it.
- `Job` mixin contains zero Redis knowledge. It builds a payload and calls `Client.push`.
- `Worker` owns process lifecycle (threads, signals). It does not know about cron specs or retry policy.
- `Scheduler` and `Cron` are pure pollers — no executor logic.

## Redis data model

Six keys total.

| Key | Type | Purpose |
|---|---|---|
| `mini_sidekiq:queue:high` | List | High-priority job payloads |
| `mini_sidekiq:queue:default` | List | Default-priority |
| `mini_sidekiq:queue:low` | List | Low-priority |
| `mini_sidekiq:schedule` | Sorted Set | Future jobs. Score = run-at unix timestamp (float). Member = JSON payload |
| `mini_sidekiq:retry` | Sorted Set | Failed jobs awaiting retry. Same shape as `schedule` |
| `mini_sidekiq:dead` | List | Jobs that exceeded max retries. Capped at 1000 via LTRIM |

Cron schedules live in **process memory** (registered at boot via `MiniSidekiq::Cron.register`). The cron poller holds the next-fire timestamp per entry, computed via `fugit`. No Redis state for cron itself — it just enqueues regular jobs.

**Job payload (single JSON shape across every key):**

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

- `jid` — random 12-char hex, used for log correlation.
- `attempts` starts at 0, bumped on each failure before being re-pushed to `retry`.
- `error_class` / `error_message` populated on the most recent failure.

## Job lifecycle / data flow

### Flow 1 — Immediate job (`perform_async`)

```
EmailJob.perform_async("a@b.com")
  └─ Job mixin builds payload {class, args, queue: "default", attempts: 0, ...}
      └─ Client.push(payload)
          └─ LPUSH mini_sidekiq:queue:default <json>

[in worker]
Executor loop:
  for queue in [queue:high, queue:default, queue:low]:
    json = RPOP queue
    if json: break
  if json:
    payload = JSON.parse(json)
    Object.const_get(payload.class).new.perform(*payload.args)
    success → loop / failure → retry path
  else:
    sleep 0.1; loop
```

### Flow 2 — Scheduled job

```
EmailJob.perform_in(60, "a@b.com")
  └─ Job mixin sets run_at = now + 60
      └─ Client.push(payload, run_at: ts)
          └─ ZADD mini_sidekiq:schedule <ts> <json>

[in worker]
Scheduler thread, every 1s:
  due = ZRANGEBYSCORE schedule -inf <now>
  for each payload:
    MULTI:
      ZREM schedule <payload>
      LPUSH queue:<payload.queue> <payload>
    EXEC
  (same loop for `retry` zset)
```

The MULTI/EXEC pair atomically claims the move so a payload can never be enqueued twice if multiple scheduler threads ever run.

### Flow 3 — Cron job

```
At boot:
  Cron.register("daily-cleanup", "0 3 * * *", CleanupJob, queue: :low)
    └─ in-memory: { name, fugit_parser, job_class, queue, next_fire_at }

Cron poller, every 5s:
  for each entry:
    if entry.next_fire_at <= now:
      Client.push(class: entry.job_class.name, args: [], queue: entry.queue)
      entry.next_fire_at = entry.fugit.next_time(now).to_f
```

Once a cron-triggered job is enqueued, it is indistinguishable from any other job. **One execution path** for everything.

## Error handling & retries

The executor's rescue block is the core retry decision:

```ruby
def execute(payload)
  klass = Object.const_get(payload["class"])
  klass.new.perform(*payload["args"])
rescue => e
  MiniSidekiq.error_handler.call(e, payload)  # placeholder hook (Sentry, etc.)
  payload["attempts"] += 1
  payload["error_class"] = e.class.name
  payload["error_message"] = e.message

  if payload["attempts"] < MAX_ATTEMPTS
    retry_at = Time.now.to_f + (BACKOFF_SECONDS * payload["attempts"])
    redis.zadd("mini_sidekiq:retry", retry_at, JSON.dump(payload))
  else
    redis.lpush("mini_sidekiq:dead", JSON.dump(payload))
    redis.ltrim("mini_sidekiq:dead", 0, 999)
  end
end
```

**Constants**

- `MAX_ATTEMPTS = 3`
- `BACKOFF_SECONDS = 5` → retries at +5s, +10s, +15s.
- Dead list capped at 1000 entries via `LTRIM`.

**Permanent-failure cases (also land in `dead`):**

- Corrupt payload JSON (`JSON::ParserError`).
- Missing job class (`NameError` from `const_get`).

These cannot be fixed by retrying, so they bypass the retry zset and go straight to `dead`. They still call `error_handler` so the placeholder hook is invoked.

**Configurable error handler:** `MiniSidekiq.error_handler` is a `Proc` taking `(exception, payload)`. Default logs to `MiniSidekiq.logger`. In real apps you would set:

```ruby
MiniSidekiq.error_handler = ->(e, ctx) { Sentry.capture_exception(e, extra: ctx) }
```

**Worker crash mid-execution:** the job is lost (we BRPOP'd it before executing, no in-flight tracking). Documented as a known limitation. The fix would be a "processing" set + reaper thread.

**Graceful shutdown:**

- Trap SIGINT/SIGTERM, set `@shutdown = true`.
- Executor threads use `BRPOP ... 1` (1s timeout, not blocking forever) so they notice shutdown within a second.
- Scheduler and cron threads check `@shutdown` between iterations.
- Process exits cleanly with no stack trace.

## Testing strategy

Test budget: ~10 minutes of the 60. Pick tests by value-per-minute, prove the contract, skip Ruby/Redis itself.

1. `Client.push` writes correct JSON to `queue:default` for an immediate job.
2. `Client.push` with `run_at` writes to `schedule` zset with the correct score.
3. `Job` mixin: `perform_in(60)` lands in `schedule` with score ≈ now+60.
4. `Scheduler.drain_once` moves a due entry from `schedule` to its queue list.
5. `Scheduler.drain_once` does **not** move a not-yet-due entry.
6. Executor: failed job lands in `retry` after 1st & 2nd fails, in `dead` after the 3rd.
7. `Cron.tick` enqueues to the right queue when next-fire is past, recomputes next-fire.
8. *(stretch)* Integration: enqueue → run worker for 1s → assert job ran.

**Test setup:** real Redis at a non-default DB index (e.g., `redis://localhost/15`) with `flushdb` in setup.

## File structure

```
lib/
  mini_sidekiq.rb              # config, redis accessor, error handler
  mini_sidekiq/
    client.rb                  # push to list or zset
    job.rb                     # perform_async / _in / _at mixin
    worker.rb                  # thread pool + signal handling
    scheduler.rb               # drain due entries (one method, looped)
    cron.rb                    # registry + poller
bin/
  mini_sidekiq                 # load Rails env + Worker.new.run
test/
  mini_sidekiq/
    client_test.rb
    job_test.rb
    scheduler_test.rb
    worker_test.rb
    cron_test.rb
```

Estimated total: ~250 LOC of source + ~150 LOC of tests.

## What I'd add with more time

- "Processing" set + reaper thread to recover jobs lost to mid-execution worker crashes.
- Web UI for queue depths, retry/dead inspection, ad-hoc retry/delete.
- Middleware chain (logging, instrumentation, transactions around `perform`).
- Per-job-class retry policy (`mini_sidekiq_options retry: 5, backoff: :exponential`).
- Connection pool for Redis at higher concurrency.
- Multi-process workers + dynamic concurrency.
- Real Sentry integration through the placeholder hook.
- Unique-job middleware (idempotency tokens via `SET NX`).
