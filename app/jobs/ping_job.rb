class PingJob < ApplicationJob
  queue_as :default

  # Sanity-demo job. Writes a timestamp to Redis cache and broadcasts it
  # over Action Cable to subscribers of PingChannel for the given app.
  def perform(app:)
    payload = {
      app: app,
      pinged_at: Time.current.iso8601(3),
      worker: "PingJob",
      message: "pong from #{app}",
    }

    Rails.cache.write("ping:#{app}:last", payload, expires_in: 1.hour)
    ActionCable.server.broadcast("ping:#{app}", payload)
  end
end
