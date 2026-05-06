class Api::V1::PricingController < ApplicationController

  def index
    request = Pricing::PricingRequest.new(
      period: params[:period],
      hotel: params[:hotel],
      room: params[:room]
    )

    unless request.valid?
      return render json: { error: request.errors.join(', ') }, status: :bad_request
    end

    service = Api::V1::PricingService.new(request: request)
    service.run

    if service.valid?
      render json: { rate: service.result }
    else
      render json: { error: service.errors.join(', ') }, status: :bad_request
    end
  end
end
