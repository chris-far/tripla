RateKey = Struct.new(:period, :hotel, :room) do
  def self.from(hash) = new(period: hash[:period], hotel: hash[:hotel], room: hash[:room])

  def to_h
    { period: period, hotel: hotel, room: room }
  end

  def cache_key = "#{period}/#{hotel}/#{room}"
end
