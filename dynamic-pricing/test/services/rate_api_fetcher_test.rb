require "test_helper"

class RateApiFetcherTest < ActiveSupport::TestCase
  PERIOD = "Summer"
  HOTEL = "FloatingPointResort"
  ROOM = "SingletonRoom"

  setup do
    @key = RateKey.new(period: PERIOD, hotel: HOTEL, room: ROOM)
    @fetcher = RateApiFetcher.new(rate_keys: [@key])
  end

  test "returns success when API returns all requested rates" do
    stub_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
      result = @fetcher.fetch
      assert_equal PricingOutcome::SUCCESS, result[:outcome]
      assert_equal 1, result[:rates].size
      assert_equal "success", result[:rates].first[:status]
      assert_equal "150.00", result[:rates].first[:rate]
      assert_empty result[:failed_rates]
    end
  end

  test "returns partial success when API response is missing some rates" do
    key2 = RateKey.new(period: PERIOD, hotel: HOTEL, room: "BooleanTwin")
    fetcher = RateApiFetcher.new(rate_keys: [@key, key2])

    stub_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
      result = fetcher.fetch
      assert_equal PricingOutcome::PARTIAL_SUCCESS, result[:outcome]
      assert_equal 1, result[:rates].size
      assert_equal 1, result[:failed_rates].size
      assert_equal "error", result[:failed_rates].first[:status]
      assert_equal "BooleanTwin", result[:failed_rates].first[:room]
    end
  end

  test "returns failure when API returns no matching rates" do
    stub_api(rates: [{ "period" => "Winter", "hotel" => HOTEL, "room" => ROOM, "rate" => "100.00" }]) do
      result = @fetcher.fetch
      assert_equal PricingOutcome::FAILURE, result[:outcome]
      assert_empty result[:rates]
      assert_equal 1, result[:failed_rates].size
    end
  end

  test "returns error on retryable HTTP status code" do
    mock = OpenStruct.new(success?: false, code: "503", body: {}.to_json)
    RateApiClient.stub(:bulk_get_rates, mock) do
      result = @fetcher.fetch
      assert_equal PricingOutcome::ERROR, result[:outcome]
      assert_empty result[:rates]
      assert_equal 1, result[:failed_rates].size
    end
  end

  test "returns error on non-retryable unsuccessful response" do
    mock = OpenStruct.new(success?: false, code: "400", body: { "error" => "Bad request" }.to_json)
    RateApiClient.stub(:bulk_get_rates, mock) do
      result = @fetcher.fetch
      assert_equal PricingOutcome::ERROR, result[:outcome]
      assert_empty result[:rates]
    end
  end

  test "returns error when response body is not valid JSON" do
    mock = OpenStruct.new(success?: true, code: "200", body: "not json")
    RateApiClient.stub(:bulk_get_rates, mock) do
      result = @fetcher.fetch
      assert_equal PricingOutcome::ERROR, result[:outcome]
    end
  end

  test "returns error when API body has status error" do
    mock = OpenStruct.new(success?: true, code: "200", body: { "status" => "error", "message" => "Service unavailable" }.to_json)
    RateApiClient.stub(:bulk_get_rates, mock) do
      result = @fetcher.fetch
      assert_equal PricingOutcome::ERROR, result[:outcome]
    end
  end

  test "returns error when API response contains no rates" do
    mock = OpenStruct.new(success?: true, code: "200", body: { "rates" => [] }.to_json)
    RateApiClient.stub(:bulk_get_rates, mock) do
      result = @fetcher.fetch
      assert_equal PricingOutcome::ERROR, result[:outcome]
    end
  end

  test "returns error on network exception" do
    RateApiClient.stub(:bulk_get_rates, ->(**_) { raise Net::ReadTimeout }) do
      result = @fetcher.fetch
      assert_equal PricingOutcome::ERROR, result[:outcome]
      assert_empty result[:rates]
    end
  end

  private

  def stub_api(rates:, &block)
    mock = OpenStruct.new(success?: true, code: "200", body: { "rates" => rates }.to_json)
    RateApiClient.stub(:bulk_get_rates, mock, &block)
  end
end
