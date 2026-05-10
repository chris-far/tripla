class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
  open_timeout ENV.fetch('RATE_API_OPEN_TIMEOUT', 2).to_i
  read_timeout ENV.fetch('RATE_API_READ_TIMEOUT', 10).to_i

  def self.get_rate(period:, hotel:, room:)
    bulk_get_rates(bulk_request: [{ period: period, hotel: hotel, room: room }])
  end

  def self.bulk_get_rates(bulk_request:)
    params = {
      attributes: bulk_request.map do |request|
        { period: request[:period], hotel: request[:hotel], room: request[:room] }
      end
    }.to_json
    self.post("/pricing", body: params)
  end
end
