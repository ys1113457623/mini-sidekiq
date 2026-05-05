# Project walkthrough

A guide to understanding this codebase. Read top-to-bottom on your first pass; later, jump to the section that matches what you're trying to do.

> Already know the stack and just want to run it? See [README.md](../README.md).
> Want the design rationale? See [the spec](superpowers/specs/2026-05-05-rails-react-multi-app-setup-design.md).

---

## 1. What this is, in one paragraph

This is a single Rails 8 application that hosts **three independent React apps** under one process: `mentee`, `career_hubs`, and `assessments`. Each app has its own URL prefix (`/mentee`, `/career-hubs`, `/assessments`), its own React tree, its own JSON API namespace under `/api/v1/<app>/`, and its own Rails layout. They share infrastructure (Postgres, Redis, Sidekiq, Action Cable) and a shared frontend layer (the API client, Tailwind setup, Cable consumer, common UI primitives), but their UI code is isolated.

A single config file — [`config/frontend_apps.yml`](../config/frontend_apps.yml) — is the source of truth for which apps exist and which are active in each environment. Flipping `enabled: false` on an app removes its routes, its API namespace, and its frontend bundle from that environment's boot.

---

## 2. Mental model

```
                          ┌─────────────────────────────────────────┐
                          │              Rails app (one)             │
                          │                                          │
   browser ──HTTP──▶  Rails router ──▶  per-app HTML controller ──▶  layout (vite_javascript_tag)
                          │                                          │
                          │                                          ▼
                          │                              <script> from Vite dev server
                          │                              (proxied by Rails to vite:3036)
                          │
                          ├──/api/v1/<app>/* ──▶  Api::V1::<App>::*Controller (JSON)
                          │
                          ├──/cable ──────────▶  Action Cable (Redis adapter)
                          │
                          ├──Active Job ─────▶  Sidekiq (Redis queue, separate process)
                          │
                          └──ActiveRecord ───▶  Postgres
```

Three things to keep in your head:

1. **One Rails monolith, many apps.** Apps are not microservices, not separate Rails apps. They're three React trees that happen to live in the same Rails repo and share the same Ruby code, models, and database. This makes cross-cutting changes (say, adding auth) trivial, while still letting each frontend evolve at its own pace.

2. **Rails serves the shell, React owns the page.** A request to `/mentee/anything/at/all` hits the same Rails action — `Mentee::PagesController#index` — which renders an HTML shell with a single `<div id="root">`. From there, react-router (running in the browser, configured with `basename="/mentee"`) decides what to show. Rails never renders a page for `/mentee/profile`; the React app does.

3. **The `enabled` flag is load-bearing.** It gates *three* things at once: the Rails route, the API namespace, and the Vite entrypoint. Read the section [Multi-app gating, in depth](#7-multi-app-gating-in-depth) to see how.

---

## 3. The HTTP request lifecycle

### A page load — `GET /mentee/profile`

1. Browser hits Rails on `localhost:3000`.
2. `config/routes.rb` runs the per-app HTML route file [`config/routes/components/mentee.rb`](../config/routes/components/mentee.rb), which says: every path under `/mentee` (including sub-paths) goes to `Mentee::PagesController#index`.
3. The controller has `layout "mentee/application"` and an empty `#index` action. Rails looks for `app/views/mentee/pages/index.html.erb` (also empty), then renders [`app/views/layouts/mentee/application.html.erb`](../app/views/layouts/mentee/application.html.erb) around it.
4. The layout emits three Vite tags via `vite_javascript_tag "mentee.jsx"` and friends. These resolve to `<script src="/vite-dev/entrypoints/mentee.jsx">` etc.
5. The browser fetches `/vite-dev/entrypoints/mentee.jsx`. Rails (via `vite-plugin-ruby`'s middleware) proxies the request to the Vite dev server (`vite:3036` in Docker, `localhost:3036` in native dev).
6. Vite serves the compiled JS module. The browser executes it. [`app/frontend/entrypoints/mentee.jsx`](../app/frontend/entrypoints/mentee.jsx) mounts `<App />` from [`app/frontend/mentee/App.jsx`](../app/frontend/mentee/App.jsx) into `#root`.
7. React-router takes over. The `/profile` part of the URL is routed *inside* the React app.

### An API call — `POST /api/v1/mentee/ping`

1. The React app calls `api('/mentee/ping', { method: 'POST' })` from [`app/frontend/shared/api/client.js`](../app/frontend/shared/api/client.js). The client adds `X-CSRF-Token` from the `<meta name="csrf-token">` tag and sends `credentials: 'same-origin'` so cookies flow.
2. `routes.rb` namespaces the request under `api/v1/mentee` via [`config/routes/api/v1/mentee.rb`](../config/routes/api/v1/mentee.rb).
3. [`Api::V1::Mentee::PingController#create`](../app/controllers/api/v1/mentee/ping_controller.rb) runs. It inherits from `Api::BaseController`, which is `ActionController::API` + CSRF protection (`null_session` strategy).
4. The controller calls `PingJob.perform_later(app: "mentee")` and immediately returns 202 with `{ enqueued: true, app: "mentee" }`.
5. Sidekiq (running as a separate container/process) picks up the job from Redis, runs [`PingJob#perform`](../app/jobs/ping_job.rb), writes a payload to `Rails.cache`, and broadcasts on `ping:mentee` over Action Cable.
6. The React component, subscribed to `PingChannel` with `app: "mentee"`, receives the payload via the WebSocket and re-renders.

---

## 4. The directory map

The most important files, grouped by responsibility:

### Configuration

| File | What it does |
|---|---|
| [`config/frontend_apps.yml`](../config/frontend_apps.yml) | **Source of truth for which apps exist.** Each entry has a mount path and an `enabled` flag, per-environment. |
| [`config/initializers/frontend_apps.rb`](../config/initializers/frontend_apps.rb) | Reads the YAML once at boot and exposes it as `Rails.application.config.frontend_apps` (and `enabled_frontend_apps` for the filtered subset). |
| [`config/routes.rb`](../config/routes.rb) | Top-level router. Defines `draw_component`/`draw_api` helpers and iterates over enabled apps to mount their routes. |
| [`config/routes/components/<app>.rb`](../config/routes/components/) | Per-app HTML routes — usually a single catch-all that hands sub-paths to react-router. |
| [`config/routes/api/v1/<app>.rb`](../config/routes/api/v1/) | Per-app JSON API routes. This is where you'll spend most of your routing time as the apps grow. |
| [`config/routes/api/v1/shared.rb`](../config/routes/api/v1/shared.rb) | Cross-app API endpoints (currently just `/health`). Always mounted, never gated. |
| [`config/database.yml`](../config/database.yml) | Postgres connection — reads `DATABASE_URL` so the same config works native + Docker. |
| [`config/cable.yml`](../config/cable.yml) | Action Cable adapter. Uses Redis DB 0. |
| [`config/initializers/sidekiq.rb`](../config/initializers/sidekiq.rb) | Sidekiq Redis config. Uses Redis DB 2. Sets Active Job adapter to `:sidekiq`. |
| [`config/environments/development.rb`](../config/environments/development.rb) | `cache_store = :redis_cache_store` on Redis DB 1. |

The Redis-database split (0/1/2) keeps Cable, cache, and queue from clobbering each other when you `redis-cli flushdb`.

### Backend

| Path | What lives here |
|---|---|
| `app/controllers/<app>/pages_controller.rb` | Renders the React shell HTML. Includes `ReactShell` concern; `index` is a no-op. |
| `app/controllers/concerns/react_shell.rb` | Shared empty-action concern for shell controllers. |
| `app/controllers/api/base_controller.rb` | Base for all JSON controllers. `ActionController::API` + CSRF + standard error rescues. |
| `app/controllers/api/v1/<app>/*_controller.rb` | Per-app API controllers. Inherit from `Api::BaseController`. |
| `app/controllers/api/v1/shared/*_controller.rb` | Cross-app API controllers. |
| `app/jobs/` | Sidekiq jobs (Active Job). `PingJob` is the demo. |
| `app/channels/` | Action Cable channels. `PingChannel` streams `ping:<app>` per-app. |
| `app/models/` | ActiveRecord models. Currently empty — there's no domain logic yet. |

### Frontend

```
app/frontend/
├── entrypoints/                # Vite entrypoints. One file = one bundle.
│   ├── mentee.jsx
│   ├── career_hubs.jsx
│   └── assessments.jsx
├── mentee/                     # Mentee app's React code
│   └── App.jsx
├── career_hubs/                # Career Hubs app's React code
│   └── App.jsx
├── assessments/                # Assessments app's React code
│   └── App.jsx
└── shared/                     # Cross-app frontend code
    ├── api/client.js           # fetch wrapper (CSRF, error handling)
    ├── cable/consumer.js       # Action Cable consumer (singleton)
    ├── ui/PingCard.jsx         # demo component used by all three apps
    └── styles/application.css  # Tailwind 4 entry: @import "tailwindcss"
```

**Per-app folders are independent.** The `mentee/` folder doesn't import from `career_hubs/`. They can both import from `shared/`. As apps grow, expect `<app>/components/`, `<app>/pages/`, `<app>/hooks/`, etc.

**`entrypoints/` files are wiring, not logic.** Each one mounts a `<BrowserRouter basename="...">` around the per-app `<App />`. Logic lives in the per-app folder.

### Layouts and views

```
app/views/
├── layouts/
│   ├── application.html.erb        # Rails default (unused in practice)
│   ├── mentee/application.html.erb # one per app — emits Vite tags for that app's bundle
│   ├── career_hubs/application.html.erb
│   └── assessments/application.html.erb
├── mentee/pages/index.html.erb     # empty — the layout does all the work
├── career_hubs/pages/index.html.erb
└── assessments/pages/index.html.erb
```

The empty `index.html.erb` files exist only because Rails needs *some* template to render — without them the action returns 204. The actual UI lives in the layout (the `<div id="root">`) and in React.

### Infra files

| File | Purpose |
|---|---|
| [`docker-compose.yml`](../docker-compose.yml) | Five services: postgres, redis, web, vite, worker. All app services share the same dev image. |
| [`Dockerfile.dev`](../Dockerfile.dev) | Dev image — Ruby 3.3.10 + Node 20 + Postgres client + build tools. Bakes in `bundle install` and `npm install`. |
| [`bin/docker-entrypoint`](../bin/docker-entrypoint) | Runs on container start: sanity-check bundle, sanity-check node_modules, run `rails db:prepare` on the web container only. |
| [`Procfile.dev`](../Procfile.dev) | Used by `bin/dev` for native dev. Runs `web` + `vite` + `worker` under foreman. |
| [`bin/dev`](../bin/dev) | Native-dev entrypoint. Ignored when running in Docker. |
| [`Dockerfile`](../Dockerfile) | **Production** Dockerfile generated by Rails. Not used in dev. |

---

## 5. Frontend pipeline: how Vite, React, and Tailwind fit

```
┌─ in dev ─────────────────────────────────────────────────────────┐
│                                                                   │
│  browser ──fetch /mentee──▶ Rails (port 3000) ──renders layout──▶ │
│                                  │                                │
│                                  │ <script src="/vite-dev/...">   │
│                                  ▼                                │
│                            vite_rails proxy middleware            │
│                                  │                                │
│                                  ▼                                │
│                        Vite dev server (port 3036)                │
│                                  │                                │
│                                  │ on-demand compiles .jsx        │
│                                  │ injects HMR client             │
│                                  ▼                                │
│                            JS module sent to browser              │
└───────────────────────────────────────────────────────────────────┘
```

- **Vite** is the bundler. In dev, it transforms JSX/TS, runs Tailwind, and serves modules over HTTP. It also runs the HMR WebSocket. We use the `vite_rails` Ruby gem (which provides view helpers) plus `vite-plugin-ruby` (which integrates Vite with the gem's conventions).

- **`vite.config.ts`** ([file](../vite.config.ts)) plugs in three things: `RubyPlugin()` (entrypoint discovery + manifest), `react()` (JSX + Fast Refresh), and `tailwindcss()` (Tailwind 4 — replaces the old PostCSS plugin).

- **Entrypoints** are auto-discovered from `app/frontend/entrypoints/`. Each file becomes one `vite_javascript_tag "<name>.jsx"` callable in views.

- **Tailwind 4** uses `@import "tailwindcss"` directly in CSS (no `tailwind.config.js`). Source globs are declared with `@source "..."` directives in [`app/frontend/shared/styles/application.css`](../app/frontend/shared/styles/application.css). The `@tailwindcss/vite` plugin compiles it.

- **HMR**: when you save a `.jsx` file, Vite pushes the change over WebSocket and React Fast Refresh swaps the component in-place. Component state is preserved when possible.

---

## 6. How services talk

```
            ┌────────────┐
            │ web (Rails)│
            └─────┬──────┘
                  │
    ┌─────────────┼──────────────────────────┐
    │             │                          │
    ▼             ▼                          ▼
┌─────────┐  ┌─────────┐                ┌───────────┐
│postgres │  │  redis  │ ◀──pubsub─────▶│  worker   │
│         │  │         │                │ (Sidekiq) │
│ AR/SQL  │  │ DB 0:   │                └───────────┘
│         │  │  Cable  │
│         │  │ DB 1:   │
│         │  │  cache  │
│         │  │ DB 2:   │
│         │  │  queue  │
└─────────┘  └─────────┘
```

- **Postgres** is the only persistent datastore. Models live in `app/models/`. There are none yet.

- **Redis** wears three hats. Each uses a separate logical DB so a `redis-cli -n 2 flushdb` only wipes Sidekiq's queue, not your cache or open WebSocket subscriptions:
  - DB 0 — Action Cable pub/sub
  - DB 1 — `Rails.cache`
  - DB 2 — Sidekiq queue

- **Sidekiq** runs in its own container (`worker` service). It pulls jobs from Redis DB 2. The web container enqueues with `SomeJob.perform_later(...)` (Active Job → Sidekiq adapter). Jobs run *outside* the request lifecycle — the controller responds immediately while the job runs asynchronously.

- **Action Cable** is mounted at `/cable` (Rails route). The browser opens a WebSocket to `ws://localhost:3000/cable`. When a job calls `ActionCable.server.broadcast("ping:mentee", payload)`, Redis pub/sub propagates to any Cable server with subscribers on `ping:mentee`. There's only one Cable server (the Rails web process), but in production with multiple Rails instances, this is how broadcasts reach all connected clients.

---

## 7. Multi-app gating, in depth

The single `enabled: true|false` flag in `config/frontend_apps.yml` controls four things, all wired through `Rails.application.config.enabled_frontend_apps`:

### 7.1. The HTML route

```ruby
# config/routes.rb
Rails.application.config.frontend_apps.each do |app, cfg|
  next unless cfg[:enabled]
  draw_component(app)        # loads config/routes/components/<app>.rb
end
```

Disabled apps don't get `draw_component` called. Their `/mentee` route doesn't exist → 404.

### 7.2. The API namespace

```ruby
# config/routes.rb (continued)
namespace :api do
  namespace :v1 do
    Rails.application.config.frontend_apps.each do |app, cfg|
      next unless cfg[:enabled]
      draw_api(app)         # loads config/routes/api/v1/<app>.rb
    end
    draw_api("shared")      # always mounted
  end
end
```

Disabled apps' `/api/v1/<app>/*` namespace doesn't exist → 404.

### 7.3. The Vite entrypoint

In **dev**, Vite compiles entrypoints lazily. A user can only request `/vite-dev/entrypoints/mentee.jsx` if a Rails layout asks for it — and a Rails layout only renders if its route exists. Disabled apps have no route, so nobody asks for the entrypoint, so Vite never compiles it. Free gating, no extra config.

In **production builds**, Vite would build all entrypoints in `app/frontend/entrypoints/` by default. To exclude disabled apps from the prod bundle, a build-time hook would filter the directory. This isn't wired up yet (see "Out of scope" in the spec) — for now, all production builds include all three apps.

### 7.4. Confirming gating

```sh
# Disable assessments
# Edit config/frontend_apps.yml: assessments → enabled: false

# Restart the web container
docker compose restart web

# Verify
curl -i http://localhost:3000/assessments        # → 404
curl -i http://localhost:3000/api/v1/assessments/ping  # → 404
curl http://localhost:3000/api/v1/shared/health  # enabled_apps no longer includes assessments
```

---

## 8. How-to recipes

### 8.1. Add an API endpoint to an existing app

Say you want `GET /api/v1/mentee/sessions` for the mentee app.

1. **Route** — add to [`config/routes/api/v1/mentee.rb`](../config/routes/api/v1/mentee.rb):
   ```ruby
   namespace :mentee do
     post "ping", to: "ping#create"
     resources :sessions, only: %i[index show]
   end
   ```
2. **Controller** — create `app/controllers/api/v1/mentee/sessions_controller.rb`:
   ```ruby
   module Api::V1::Mentee
     class SessionsController < Api::BaseController
       def index
         render json: { sessions: [] }
       end

       def show
         render json: { session: { id: params[:id] } }
       end
     end
   end
   ```
3. **Test** with `curl`:
   ```sh
   curl http://localhost:3000/api/v1/mentee/sessions
   ```

### 8.2. Add a page to an existing app

Inside a single app, react-router handles routing. To add `/mentee/profile`:

1. Create `app/frontend/mentee/pages/Profile.jsx`:
   ```jsx
   export default function Profile() {
     return <div className="p-8">Profile page</div>
   }
   ```
2. Wire into [`app/frontend/mentee/App.jsx`](../app/frontend/mentee/App.jsx):
   ```jsx
   import Profile from './pages/Profile'
   // ...
   <Routes>
     <Route path="/" element={<Home />} />
     <Route path="/profile" element={<Profile />} />
     <Route path="*" element={<NotFound />} />
   </Routes>
   ```
3. Visit http://localhost:3000/mentee/profile.

No Rails-side change needed — the catch-all `get "(*path)"` route already matches.

### 8.3. Add a new app

Say `coaching`.

1. **Register** in [`config/frontend_apps.yml`](../config/frontend_apps.yml):
   ```yaml
   default: &default
     apps:
       mentee: { mount: /mentee, enabled: true }
       career_hubs: { mount: /career-hubs, enabled: true }
       assessments: { mount: /assessments, enabled: true }
       coaching: { mount: /coaching, enabled: true }   # new
   ```
2. **Routes**:
   - `config/routes/components/coaching.rb`:
     ```ruby
     scope "/coaching", as: :coaching do
       get "(*path)", to: "coaching/pages#index", format: false
     end
     ```
   - `config/routes/api/v1/coaching.rb`:
     ```ruby
     namespace :coaching do
       # endpoints go here
     end
     ```
3. **Controller** — `app/controllers/coaching/pages_controller.rb`:
   ```ruby
   module Coaching
     class PagesController < ApplicationController
       include ReactShell
       layout "coaching/application"
     end
   end
   ```
4. **Layout** — `app/views/layouts/coaching/application.html.erb`: copy from `mentee/application.html.erb` and swap two strings (title and `vite_javascript_tag "coaching.jsx"`).
5. **Empty view** — `app/views/coaching/pages/index.html.erb` (touch it).
6. **Frontend** — `app/frontend/coaching/App.jsx` (copy from `mentee/App.jsx`, change `appName` and `appKey`).
7. **Entrypoint** — `app/frontend/entrypoints/coaching.jsx` (copy from `mentee.jsx`, change `App` import and `basename`).
8. **(Optional) Allow Cable subscription** — add `"coaching"` to `ALLOWED_APPS` in [`app/channels/ping_channel.rb`](../app/channels/ping_channel.rb).
9. Restart the `web` container.

### 8.4. Add a model

Standard Rails. From inside the web container:

```sh
docker compose exec web bundle exec rails g model Session user_id:integer mentor_id:integer started_at:datetime
docker compose exec web bundle exec rails db:migrate
```

The migration runs in the Postgres container; the model file appears in `app/models/session.rb` on your host (because the source is volume-mounted).

### 8.5. Run a Rails console / debugger

```sh
docker compose exec web bundle exec rails console
docker compose exec web bash      # then run anything ad-hoc
```

For `binding.pry` / `debugger` to work interactively, `bin/dev` natively (not Docker) is easier — Docker container stdin attachment is fiddlier.

---

## 9. Where to look when something breaks

| Symptom | First place to check |
|---|---|
| `localhost:3000` doesn't respond | Is the `web` container running? `docker compose ps`. Is anything listening on 3000? `lsof -iTCP:3000`. |
| Page loads but is blank | Open browser devtools → Network tab. Look for a 404 on `/vite-dev/entrypoints/<app>.jsx`. If 404, the `vite` container isn't running or isn't reachable. |
| Page loads but no styling | Vite couldn't compile Tailwind. Check `docker compose logs vite`. |
| `POST /api/v1/...` returns 401/422 | Probably CSRF. Confirm the request includes `X-CSRF-Token` and `credentials: 'same-origin'`. Use the shared `api()` client; don't roll your own `fetch`. |
| Sidekiq job never runs | Is `worker` container up? `docker compose logs worker`. Is Redis up? Job in queue? `docker compose exec redis redis-cli -n 2 LLEN queue:default`. |
| Action Cable broadcast doesn't reach the browser | Open devtools → Network → WS tab. There should be a `cable` connection. If not, check `app/channels/application_cable/connection.rb`. If yes, check that the channel name and params match between subscriber (JS) and broadcaster (job/controller). |
| `bundle install` "needed but slow" | The bundle volume drifted from the Gemfile. Run `docker compose exec web bundle install`. |
| Routes that should exist 404 | Check `config/frontend_apps.yml` — is the app `enabled: true`? Restart `web` after changing the YAML. |

The fastest way to triage is usually:

```sh
docker compose ps              # are all five services up?
docker compose logs -f         # tail everything
curl -i http://localhost:3000/api/v1/shared/health
```

The health endpoint reports Postgres + Redis + the list of currently enabled apps. If that returns 200 and lists all three apps, the boot is healthy and the issue is in your code, not the infrastructure.

---

## 10. What's NOT here yet

- **Auth.** No login, no current_user, no Devise. The CSRF token is sent but no backend session check exists. When you add auth, the `Api::BaseController` is the natural place to require it (`before_action :require_login`), and `ApplicationCable::Connection` should identify by `current_user`.
- **Real models / domain logic.** `app/models/` is empty. Each app's domain will fill in over time.
- **Tests.** Minitest is configured (Rails 8 default) but no tests exist beyond the generated scaffolding. Add to `test/controllers/`, `test/models/`, etc.
- **Production deployment config.** Rails generated a `Dockerfile` (production) and a `kamal` config — not yet wired up.
- **CI.** A GitHub Actions skeleton exists at `.github/workflows/ci.yml` but isn't tuned for this multi-app setup yet.

---

## 11. Further reading

- [Spec / design rationale](superpowers/specs/2026-05-05-rails-react-multi-app-setup-design.md) — *why* the structure is what it is, with trade-offs we considered.
- [README](../README.md) — minimal "how to run it" instructions.
- [Rails 8 release notes](https://guides.rubyonrails.org/8_0_release_notes.html) — what changed since older Rails versions you might know.
- [Vite Ruby docs](https://vite-ruby.netlify.app/) — for `vite_rails` / `vite-plugin-ruby` specifics.
- [Tailwind v4](https://tailwindcss.com/blog/tailwindcss-v4) — config-via-CSS approach this project uses.
- [Sidekiq getting started](https://github.com/sidekiq/sidekiq/wiki/Getting-Started).
