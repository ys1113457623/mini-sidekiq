# Loads config/frontend_apps.yml and exposes it as
# Rails.application.config.frontend_apps — a hash like:
#   { mentee: { mount: "/mentee", enabled: true }, ... }
#
# Used to gate routes (HTML + API) and to introspect mounts in views/controllers.

require "yaml"

raw = YAML.load(
  ERB.new(Rails.root.join("config/frontend_apps.yml").read).result,
  aliases: true
)

env_config = raw.fetch(Rails.env, raw.fetch("default", {}))
apps = env_config.fetch("apps", {})

Rails.application.config.frontend_apps = apps.transform_keys(&:to_sym).transform_values do |cfg|
  cfg.transform_keys(&:to_sym)
end.freeze

Rails.application.config.enabled_frontend_apps =
  Rails.application.config.frontend_apps.select { |_, cfg| cfg[:enabled] }.freeze
