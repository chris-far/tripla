class PricingParams
  include ActiveModel::Model

  VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
  VALID_HOTELS = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  VALID_ROOMS = %w[SingletonRoom BooleanTwin RestfulKing].freeze

  attr_accessor :period, :hotel, :room

  validates :period, :hotel, :room, presence: true
  validates :period, inclusion: { in: VALID_PERIODS, message: "must be one of: #{VALID_PERIODS.join(', ')}" }
  validates :hotel, inclusion: { in: VALID_HOTELS, message: "must be one of: #{VALID_HOTELS.join(', ')}" }
  validates :room, inclusion: { in: VALID_ROOMS, message: "must be one of: #{VALID_ROOMS.join(', ')}" }
end
