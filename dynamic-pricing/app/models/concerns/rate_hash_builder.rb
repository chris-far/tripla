module RateHashBuilder
  module_function

  def to_rate_hash(rate_key, rate: nil, status: nil, error: nil)
    { period: rate_key.period, hotel: rate_key.hotel, room: rate_key.room, rate: rate, status: status, error: error }.compact
  end
end
