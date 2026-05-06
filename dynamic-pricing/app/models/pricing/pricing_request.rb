module Pricing
  class PricingRequest
    VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
    VALID_HOTELS = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
    VALID_ROOMS = %w[SingletonRoom BooleanTwin RestfulKing].freeze

    attr_reader :period, :hotel, :room, :errors

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
      @errors = []
    end

    def valid?
      errors.clear

      # Validate required parameters
      missing = []
      missing << "period" unless period.present?
      missing << "hotel" unless hotel.present?
      missing << "room" unless room.present?
      if missing.any?
        errors << "Missing required #{'parameter'.pluralize(missing.size)}: #{missing.join(', ')}"
        return false
      end

      # Validate parameter values
      errors << "Invalid period. Must be one of: #{VALID_PERIODS.join(', ')}" unless VALID_PERIODS.include?(period)
      errors << "Invalid hotel. Must be one of: #{VALID_HOTELS.join(', ')}" unless VALID_HOTELS.include?(hotel)
      errors << "Invalid room. Must be one of: #{VALID_ROOMS.join(', ')}" unless VALID_ROOMS.include?(room)
      errors.empty?
    end
  end
end