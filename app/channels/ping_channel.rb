class PingChannel < ApplicationCable::Channel
  ALLOWED_APPS = %w[mentee career_hubs assessments].freeze

  def subscribed
    app = params[:app].to_s
    return reject unless ALLOWED_APPS.include?(app)

    stream_from "ping:#{app}"
  end
end
