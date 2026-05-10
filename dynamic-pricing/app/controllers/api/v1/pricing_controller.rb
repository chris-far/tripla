class Api::V1::PricingController < ApplicationController

  def index
    pricing_params = [PricingParams.new(self.pricing_params)]
    return if render_param_errors(pricing_params)
    render_prices(pricing_params)
  end

  def bulk
    pricing_params = params.require(:pricing).map { |p| PricingParams.new(pricing_params(p)) }
    return if render_param_errors(pricing_params)
    render_prices(pricing_params)
  end

  private

  def render_prices(pricing_params)
    service = Api::V1::PricingService.new(pricing_params: pricing_params)
    service.run

    if service.valid?
      render json: { outcome: service.outcome, message: service.message, rates: service.rates }.compact
    else
      render json: { outcome: service.outcome, message: service.message }, status: get_status(service.outcome)
    end
  end

  def render_param_errors(pricing_params)
    invalid_params = pricing_params.reject(&:valid?)
    if invalid_params.any?
      errors = invalid_params.flat_map { |p| p.errors.full_messages }
      render json: { outcome: PricingOutcome::ERROR, message: "Invalid parameters were provided", errors: errors }, status: :bad_request
    end
  end

  def pricing_params(p = params)
    p.permit(:period, :hotel, :room)
  end

  def get_status(outcome)
    case outcome
    when PricingOutcome::ERROR then :bad_gateway
    when PricingOutcome::FAILURE then :service_unavailable
    else :bad_request
    end
  end
end