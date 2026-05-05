module Api
  module V1
    module Shared
      class HealthController < Api::BaseController
        def index
          render json: {
            ok: true,
            time: Time.current.iso8601,
            redis: redis_ping,
            postgres: postgres_ping,
            enabled_apps: Rails.application.config.enabled_frontend_apps.keys,
          }
        end

        private

        def redis_ping
          Rails.cache.write("health:probe", "ok", expires_in: 1.minute)
          Rails.cache.read("health:probe") == "ok"
        rescue StandardError => e
          { error: e.message }
        end

        def postgres_ping
          ActiveRecord::Base.connection.execute("SELECT 1")
          true
        rescue StandardError => e
          { error: e.message }
        end
      end
    end
  end
end
