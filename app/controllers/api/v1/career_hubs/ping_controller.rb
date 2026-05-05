module Api
  module V1
    module CareerHubs
      class PingController < Api::BaseController
        APP = "career_hubs".freeze

        def create
          PingJob.perform_later(app: APP)
          render json: { enqueued: true, app: APP }, status: :accepted
        end
      end
    end
  end
end
