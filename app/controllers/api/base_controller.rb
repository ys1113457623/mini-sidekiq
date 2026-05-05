module Api
  class BaseController < ActionController::API
    include ActionController::Cookies
    include ActionController::RequestForgeryProtection
    protect_from_forgery with: :null_session

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActionController::ParameterMissing, with: :render_bad_request

    private

    def render_not_found(error)
      render json: { error: "not_found", message: error.message }, status: :not_found
    end

    def render_bad_request(error)
      render json: { error: "bad_request", message: error.message }, status: :bad_request
    end
  end
end
