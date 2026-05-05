Rails.application.routes.draw do
  # Loads a per-app HTML route file from config/routes/components/<name>.rb
  def draw_component(name)
    instance_eval(File.read(Rails.root.join("config/routes/components/#{name}.rb")))
  end

  # Loads a per-app API route file from config/routes/api/v1/<name>.rb
  def draw_api(name)
    instance_eval(File.read(Rails.root.join("config/routes/api/v1/#{name}.rb")))
  end

  # Health check (always on)
  get "up" => "rails/health#show", as: :rails_health_check

  # HTML shells, gated by config/frontend_apps.yml
  Rails.application.config.frontend_apps.each do |app, cfg|
    next unless cfg[:enabled]
    draw_component(app)
  end

  # JSON API namespace, gated app-by-app + always-on shared
  namespace :api do
    namespace :v1 do
      Rails.application.config.frontend_apps.each do |app, cfg|
        next unless cfg[:enabled]
        draw_api(app)
      end
      draw_api("shared")
    end
  end

  mount ActionCable.server => "/cable"

  # Convenience: visit "/" → first enabled app's mount path.
  if (first_enabled = Rails.application.config.enabled_frontend_apps.values.first)
    root to: redirect(first_enabled[:mount])
  end
end
