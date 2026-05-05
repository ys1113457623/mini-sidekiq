module Api
  module V1
    module Mentee
      class PingController < Api::BaseController
        APP = "mentee".freeze

        def create
          PingJob.perform_later(app: APP)
          render json: { enqueued: true, app: APP }, status: :accepted
        end
      end
    end
  end
end
