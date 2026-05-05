# dummy-rails

Multi-app Rails 8 monolith hosting independent React apps under one Rails process. See the design spec at [`docs/superpowers/specs/2026-05-05-rails-react-multi-app-setup-design.md`](docs/superpowers/specs/2026-05-05-rails-react-multi-app-setup-design.md).

## Stack

- Ruby 3.3.10 / Rails 8.1
- Postgres 16 + Redis 7 (Docker Compose)
- React 19 + Vite + Tailwind CSS 4
- Sidekiq (Active Job) + Action Cable (Redis adapter) + Redis cache store

## Apps

The monolith currently hosts three apps mounted at:

- `/mentee`
- `/career-hubs`
- `/assessments`

Each app has its own React tree under `app/frontend/<app>/`, its own Rails layout under `app/views/layouts/<app>/`, and its own JSON API namespace under `/api/v1/<app>/`. All four pieces are gated by [`config/frontend_apps.yml`](config/frontend_apps.yml) — flip an app's `enabled` flag and that app's HTML route, API namespace, and Vite entrypoint all stop existing for the next boot.

## Running everything in Docker (recommended)

```sh
docker compose up
```

That single command builds the image (first time only — takes a few minutes) and starts five containers:

- `postgres` — Postgres 16
- `redis`    — Redis 7
- `web`      — Rails on http://localhost:3000
- `vite`     — Vite dev server on http://localhost:3036 (proxied through Rails)
- `worker`   — Sidekiq

The `web` container automatically runs `rails db:prepare` on startup, so the database is created/migrated for you. Edits to source files are live-reloaded — `.` is mounted into each container.

`Ctrl+C` stops everything. `docker compose up -d` runs detached.

### Useful commands inside the containers

```sh
docker compose exec web bundle exec rails console        # Rails console
docker compose exec web bundle exec rails routes          # show routes
docker compose exec web bundle exec rails db:migrate      # run a new migration
docker compose exec web bash                              # shell into the web container
docker compose exec postgres psql -U dummy dummy_rails_development
docker compose logs -f web                                # tail Rails logs
```

### When Gemfile or package.json changes

The image bakes in deps, but the bundle cache and node_modules are persistent volumes so a host edit alone doesn't trigger reinstall. Run:

```sh
docker compose exec web bundle install   # after Gemfile change
docker compose exec web npm install      # after package.json change
```

If the image itself becomes stale (rare), rebuild:

```sh
docker compose build
```

## Native dev (alternative — faster reload on macOS)

If you'd rather run the app processes natively on your machine and only Postgres/Redis in Docker, the original script still works:

```sh
docker compose up -d postgres redis      # services only
bin/dev                                    # runs rails + vite + sidekiq via foreman
```

This requires `rbenv local 3.3.10`, `bundle install`, and `npm install` on the host first.

Visit any of:

- http://localhost:3000/mentee
- http://localhost:3000/career-hubs
- http://localhost:3000/assessments

Each shows a sanity-demo card with a "Ping" button that exercises the full stack: HTTP API → Sidekiq enqueue (Redis) → Job runs → writes to Redis cache → broadcasts on Action Cable (Redis pub/sub) → React subscriber re-renders. If anything is misconfigured, the demo breaks loudly.

## Health endpoint

```
GET /api/v1/shared/health
```

Returns Postgres + Redis liveness and the list of currently enabled apps.

## Switching focus to a single app

Edit `config/frontend_apps.yml` and set `enabled: false` on the apps you don't want to focus on, then restart `bin/dev`. Disabled apps' routes return 404, their API namespace doesn't exist, and Vite stops compiling their entrypoint.

## Adding a new app

1. Add the app to `config/frontend_apps.yml`.
2. Create per-app route files at `config/routes/components/<app>.rb` (HTML) and `config/routes/api/v1/<app>.rb` (API).
3. Create the controller(s) at `app/controllers/<app>/pages_controller.rb` and `app/controllers/api/v1/<app>/`.
4. Create the layout at `app/views/layouts/<app>/application.html.erb` and an empty index view at `app/views/<app>/pages/index.html.erb`.
5. Create `app/frontend/<app>/App.jsx` and `app/frontend/entrypoints/<app>.jsx`.
6. Restart `bin/dev`.

## Testing

```sh
bundle exec rails test
```
