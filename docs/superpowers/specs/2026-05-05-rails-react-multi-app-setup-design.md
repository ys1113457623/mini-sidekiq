# Rails 8 + React multi-app sandbox — design

**Date:** 2026-05-05
**Status:** Approved (brainstorming)
**Reference:** patterns adapted from `/Users/lscypher/Workspace/myinterviewtrainer`

## Goal

Stand up a fresh Rails 8 monolith in `/Users/lscypher/Workspace/dummy-rails` that hosts **multiple independent React apps** (initially `mentee`, `career_hubs`, `assessments`) under one Rails process, with a clean `/api/v1/...` JSON layer, and Postgres + Redis services running in Docker. A `config/frontend_apps.yml` file decides which apps are active in each environment, gating routes (HTML and API) and frontend bundles.

The setup must prove every component works end-to-end via a tiny per-app sanity demo (Tailwind page + Sidekiq job + Action Cable broadcast).

## Stack

| Layer | Choice |
|---|---|
| Ruby | 3.3.10 (managed via rbenv, pinned in `.ruby-version`) |
| Rails | 8.0.x — full Rails (not API-only); each app gets a Rails layout + Vite-mounted React |
| Database | Postgres 16 (Docker container) |
| Redis | Redis 7 (Docker container) — used for Sidekiq queue, Rails cache store, Action Cable |
| JS bundler | Vite via `vite_rails` (`vite-plugin-ruby`) |
| React | 18.x |
| Routing inside each React app | `react-router` v6 |
| CSS | Tailwind CSS 3 via Vite's PostCSS plugin |
| Background jobs | Sidekiq (Active Job adapter) — overrides Rails 8's Solid Queue default |
| Cache store | `:redis_cache_store` — overrides Rails 8's Solid Cache default |
| Action Cable adapter | `redis` — overrides Rails 8's Solid Cable default |
| Testing | Minitest (Rails 8 default) |
| Auth | None in this iteration |
| State management library | None upfront; per-app addition (Redux Toolkit, Zustand, etc.) when actually needed |

Rails 8's Solid* defaults are deliberately replaced because the user explicitly wants the classic Redis-backed stack to learn that pattern.

## Project structure

```
dummy-rails/
├── docker-compose.yml
├── .env                                # DATABASE_URL, REDIS_URL (gitignored)
├── .env.example                        # checked-in template
├── .ruby-version                       # 3.3.6
├── Gemfile
├── Procfile.dev                        # rails + vite + sidekiq (run via bin/dev)
├── vite.config.mts
├── tailwind.config.js
├── postcss.config.js
├── package.json
│
├── docs/
│   └── superpowers/specs/
│       └── 2026-05-05-rails-react-multi-app-setup-design.md
│
├── config/
│   ├── routes.rb                       # uses draw_component / draw_api helpers
│   ├── routes/
│   │   ├── components/                 # per-app HTML shell routes
│   │   │   ├── mentee.rb
│   │   │   ├── career_hubs.rb
│   │   │   └── assessments.rb
│   │   └── api/
│   │       └── v1/
│   │           ├── mentee.rb           # /api/v1/mentee/*
│   │           ├── career_hubs.rb
│   │           ├── assessments.rb
│   │           └── shared.rb           # /api/v1/shared/*
│   ├── frontend_apps.yml               # mount paths + enabled flags per env
│   ├── database.yml                    # reads DATABASE_URL
│   ├── cable.yml                       # adapter: redis (reads REDIS_URL)
│   ├── vite.json                       # Vite client config (root, port, etc.)
│   └── initializers/
│       ├── frontend_apps.rb            # parses YAML → Rails.application.config.frontend_apps
│       ├── sidekiq.rb                  # Redis URL config
│       └── redis.rb                    # cache_store config
│
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb
│   │   ├── mentee/pages_controller.rb
│   │   ├── career_hubs/pages_controller.rb
│   │   ├── assessments/pages_controller.rb
│   │   └── api/
│   │       ├── base_controller.rb      # ActionController::API + JSON error handling
│   │       └── v1/
│   │           ├── mentee/...
│   │           ├── career_hubs/...
│   │           ├── assessments/...
│   │           └── shared/...
│   │
│   ├── jobs/
│   │   └── ping_job.rb                 # demo Sidekiq job
│   │
│   ├── channels/
│   │   └── ping_channel.rb             # demo Action Cable channel
│   │
│   ├── views/layouts/
│   │   ├── application.html.erb        # default
│   │   ├── mentee/application.html.erb
│   │   ├── career_hubs/application.html.erb
│   │   └── assessments/application.html.erb
│   │
│   └── frontend/                       # Vite source root
│       ├── mentee/
│       │   ├── App.jsx
│       │   ├── pages/
│       │   ├── components/
│       │   └── hooks/
│       ├── career_hubs/                # same shape
│       ├── assessments/                # same shape
│       ├── shared/
│       │   ├── api/
│       │   │   └── client.js           # fetch wrapper, csrf, error handling
│       │   ├── ui/                     # cross-app primitives (Button, Card)
│       │   ├── cable/
│       │   │   └── consumer.js         # Action Cable consumer
│       │   └── styles/
│       │       └── application.css     # Tailwind directives
│       └── entrypoints/                # Vite entrypoints (one per app)
│           ├── mentee.jsx
│           ├── career_hubs.jsx
│           └── assessments.jsx
```

Note: directory names use `snake_case` for Rails conventions (`career_hubs`, `assessments`) and `kebab-case` only for URLs (`/career-hubs`).

## Configuration: `frontend_apps.yml`

Single source of truth for which apps exist, where they mount, and which are active in each Rails env.

```yaml
default: &default
  apps:
    mentee:
      mount: /mentee
      enabled: true
    career_hubs:
      mount: /career-hubs
      enabled: true
    assessments:
      mount: /assessments
      enabled: true

development:
  <<: *default
  apps:
    mentee:
      mount: /mentee
      enabled: true
    career_hubs:
      mount: /career-hubs
      enabled: false
    assessments:
      mount: /assessments
      enabled: false

test:
  <<: *default

production:
  <<: *default
```

`config/initializers/frontend_apps.rb` reads it and exposes `Rails.application.config.frontend_apps` as a hash with symbol keys (`{ mentee: { mount: '/mentee', enabled: true }, ... }`).

## Routing — `config/routes.rb`

Adopts mit's `draw_component` pattern. The same YAML drives both HTML and API mounting.

```ruby
Rails.application.routes.draw do
  def draw_component(name)
    instance_eval(File.read(Rails.root.join("config/routes/components/#{name}.rb")))
  end

  def draw_api(name)
    instance_eval(File.read(Rails.root.join("config/routes/api/v1/#{name}.rb")))
  end

  # HTML shells, one per enabled app
  Rails.application.config.frontend_apps.each do |app, cfg|
    next unless cfg[:enabled]
    draw_component(app)
  end

  # JSON API namespace
  namespace :api do
    namespace :v1 do
      Rails.application.config.frontend_apps.each do |app, cfg|
        next unless cfg[:enabled]
        draw_api(app)
      end
      draw_api('shared')   # cross-app endpoints (e.g., /api/v1/shared/me, /api/v1/shared/health)
    end
  end

  mount ActionCable.server => '/cable'
end
```

### Per-app HTML route file (example)

`config/routes/components/mentee.rb`:

```ruby
scope '/mentee', as: :mentee do
  # Single catch-all so react-router inside the app handles sub-paths
  get '(*path)', to: 'mentee/pages#index'
end
```

### Per-app API route file (example)

`config/routes/api/v1/mentee.rb`:

```ruby
namespace :mentee do
  # Domain resources go here as the app grows.
  # For the sanity demo:
  post 'ping', to: 'ping#create'
end
```

### Shared API routes

`config/routes/api/v1/shared.rb`:

```ruby
namespace :shared do
  get 'health', to: 'health#index'
  # resource :me  (when auth lands)
end
```

## Controllers

### HTML shell controller (one per app)

```ruby
# app/controllers/mentee/pages_controller.rb
class Mentee::PagesController < ApplicationController
  layout 'mentee/application'

  def index
    # The React app handles all sub-routes; this just renders the shell.
  end
end
```

### API base controller

```ruby
# app/controllers/api/base_controller.rb
class Api::BaseController < ActionController::API
  include ActionController::Cookies
  include ActionController::RequestForgeryProtection
  protect_from_forgery with: :null_session

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActionController::ParameterMissing, with: :render_bad_request
  rescue_from StandardError, with: :render_server_error if Rails.env.production?

  private

  def render_not_found(error)
    render json: { error: 'not_found', message: error.message }, status: :not_found
  end

  def render_bad_request(error)
    render json: { error: 'bad_request', message: error.message }, status: :bad_request
  end

  def render_server_error(error)
    Rails.logger.error(error)
    render json: { error: 'server_error' }, status: :internal_server_error
  end
end
```

Notes:

- `ActionController::API` doesn't include CSRF protection by default; we mix in `RequestForgeryProtection` and use the `:null_session` strategy. That means: a non-GET request without a valid `X-CSRF-Token` gets an empty session (so any `current_user`-style lookup finds nothing) instead of a 422. For state-changing endpoints, controllers must explicitly check that an authenticated user exists — relying on session auth rejects the request implicitly.
- Once user authentication lands, swap `:null_session` for `:exception` and require login for the relevant endpoints.

API controllers per-app inherit from `Api::BaseController` and live in `app/controllers/api/v1/<app>/`.

## Layouts (per app)

```erb
<%# app/views/layouts/mentee/application.html.erb %>
<!DOCTYPE html>
<html>
  <head>
    <title>Mentee</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <%= csrf_meta_tags %>
    <%= vite_client_tag %>
    <%= vite_javascript_tag 'mentee' %>
    <%= vite_stylesheet_tag 'mentee' %>
  </head>
  <body>
    <div id="root"></div>
  </body>
</html>
```

Identical structure for `career_hubs/application.html.erb` and `assessments/application.html.erb`, each loading its own entrypoint.

## Frontend

### Per-app source folder shape

```
app/frontend/mentee/
├── App.jsx                # top component, sets up react-router + providers
├── pages/                 # route-level components (Home.jsx, Profile.jsx, ...)
├── components/            # mentee-specific components
└── hooks/                 # mentee-specific hooks
```

### Vite entrypoint (example)

```jsx
// app/frontend/entrypoints/mentee.jsx
import React from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from '../mentee/App'
import '../shared/styles/application.css'

createRoot(document.getElementById('root')).render(
  <BrowserRouter basename="/mentee">
    <App />
  </BrowserRouter>,
)
```

### Shared API client

```js
// app/frontend/shared/api/client.js
const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content

export async function api(path, { method = 'GET', body, headers = {} } = {}) {
  const res = await fetch(`/api/v1${path}`, {
    method,
    credentials: 'same-origin',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-CSRF-Token': csrfToken(),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) throw await res.json().catch(() => ({ error: 'unknown' }))
  return res.json()
}
```

### Tailwind

`app/frontend/shared/styles/application.css` contains the three Tailwind directives. `tailwind.config.js` `content` glob covers `app/frontend/**/*.{js,jsx,ts,tsx}` and `app/views/**/*.html.erb`.

### Vite config

```ts
// vite.config.mts
import { defineConfig } from 'vite'
import RubyPlugin from 'vite-plugin-ruby'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [RubyPlugin(), react()],
})
```

`vite-plugin-ruby` autodiscovers files in `app/frontend/entrypoints/` as entrypoints. In **dev mode**, Vite compiles entrypoints lazily on request — disabled apps' bundles never get built because their HTML pages don't exist (their routes are gated by `enabled`). No extra gating logic needed for dev.

For **production builds**, `bin/setup` (and CI) runs a small pre-build step that, based on the active env's YAML, removes (or symlinks-only-the-enabled) entrypoints under a temp directory before `vite build`. Spec for that is left to the implementation plan.

## Services & infrastructure

### `docker-compose.yml`

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: dummy
      POSTGRES_PASSWORD: dummy
      POSTGRES_DB: dummy_rails_development
    ports: ['5432:5432']
    volumes: ['postgres_data:/var/lib/postgresql/data']

  redis:
    image: redis:7
    ports: ['6379:6379']
    volumes: ['redis_data:/data']

volumes:
  postgres_data:
  redis_data:
```

### `.env.example`

```
DATABASE_URL=postgres://dummy:dummy@localhost:5432/dummy_rails_development
REDIS_URL=redis://localhost:6379
```

`.env` is gitignored; `.env.example` is checked in.

### Sidekiq init

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server { |c| c.redis = { url: ENV.fetch('REDIS_URL') + '/2' } }
Sidekiq.configure_client { |c| c.redis = { url: ENV.fetch('REDIS_URL') + '/2' } }
Rails.application.config.active_job.queue_adapter = :sidekiq
```

### Cache + Cable

```ruby
# config/environments/development.rb
config.cache_store = :redis_cache_store, { url: ENV.fetch('REDIS_URL') + '/1' }
```

```yaml
# config/cable.yml
development:
  adapter: redis
  url: <%= "#{ENV.fetch('REDIS_URL')}/0" %>
```

Redis DB allocation: **DB 0** = Action Cable, **DB 1** = cache, **DB 2** = Sidekiq queue. Separated so flushing one doesn't blow away the others.

### Procfile.dev

```
web:     bin/rails server -p 3000
vite:    bin/vite dev
worker:  bundle exec sidekiq
```

`bin/dev` (provided by Rails) runs `foreman start -f Procfile.dev`.

## Sanity-check feature

Each enabled app exposes one route at its mount path that proves the full stack works.

Per app, the `App.jsx` renders a Tailwind-styled card with:

1. The app name (proves Vite + Tailwind + per-app entrypoint).
2. A "Ping" button that POSTs to `/api/v1/<app>/ping` (proves API + CSRF + same-origin auth).
3. The API enqueues a `PingJob` (proves Sidekiq + Redis queue).
4. The job writes a timestamp to `Rails.cache` (proves Redis cache) and broadcasts on a `PingChannel` for the user (proves Action Cable + Redis pub/sub).
5. The React component subscribes to the channel via `app/frontend/shared/cable/consumer.js` and re-renders the timestamp (proves end-to-end real-time).

If any service is misconfigured, the corresponding step fails visibly.

## Authentication & CSRF

- React apps are same-origin with Rails. No JWT, no separate token store.
- Rails session cookie + CSRF token (read from `<meta name="csrf-token">`, sent as `X-CSRF-Token` header on non-GET requests).
- The shared `api/client.js` handles the header automatically.
- A custom CSRF check in `Api::BaseController` (since `ActionController::API` doesn't include the default `protect_from_forgery`).

User-level auth (login, sessions) is **out of scope**. When added later, a `/api/v1/shared/sessions` endpoint family is the natural insertion point.

## Run loop

```sh
docker compose up -d            # Postgres + Redis
bin/setup                       # bundle, npm install, db:create, db:migrate
bin/dev                         # rails (3000) + vite (3036) + sidekiq
```

Switching focus to a single app:

```sh
# Edit config/frontend_apps.yml: set enabled: false on apps you don't want
# Restart bin/dev
```

## Out of scope

- Authentication / Devise
- Production Dockerfile and deployment config
- CI configuration
- RSpec (sticking with Minitest default)
- A state-management library (added per-app when needed)
- API documentation / OpenAPI / Rswag
- A shared top-level shell across apps (each app builds its own header/nav)

## Open assumptions

These were stated and confirmed in brainstorming:

1. Each app is a fully independent React tree. No shared top-level shell across apps.
2. `react-router` v6 inside each app, with `basename` matching the app's mount path.
3. No state-management library installed at scaffold time.
4. No authentication.
5. Postgres + Redis run in Docker; Sidekiq runs natively as a Procfile process.

## Implementation order (for the plan that follows)

1. Initialize Rails 8 app skeleton (`rails new` with Postgres + Vite).
2. Add `docker-compose.yml`, `.env.example`, get `bin/rails db:create` working against Dockerized Postgres.
3. Wire Redis cache, Sidekiq, Action Cable adapter.
4. Add `frontend_apps.yml` + initializer + modular `routes.rb` + per-app route files.
5. Generate per-app controllers, layouts, frontend folders, entrypoints (one app at a time, starting with `mentee`).
6. Add Tailwind + the shared API client + Action Cable consumer.
7. Build the per-app sanity demo.
8. Replicate the per-app pieces for `career_hubs` and `assessments`.
9. Verify the `enabled` flag actually gates routes + API + bundles.
