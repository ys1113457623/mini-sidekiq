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

## First-time setup

```sh
# 1. Pin Ruby and install gems
rbenv local 3.3.10
bundle install

# 2. Install JS deps
npm install

# 3. Bring up Postgres + Redis
docker compose up -d

# 4. Create a .env (defaults match docker-compose.yml — usually no edits needed)
cp .env.example .env

# 5. Create + migrate the dev database
bundle exec rails db:create db:migrate
```

## Running the dev server

```sh
bin/dev
```

This runs three processes via Foreman + `Procfile.dev`:

- `web`    — Rails on http://localhost:3000
- `vite`   — Vite dev server on http://localhost:3036 (proxied through Rails)
- `worker` — Sidekiq

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
