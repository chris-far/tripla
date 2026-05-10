require "test_helper"

class RateRefreshServiceTest < ActiveSupport::TestCase
  PERIOD = "Summer"
  HOTEL = "FloatingPointResort"
  ROOM = "SingletonRoom"

  setup do
    @key = RateKey.new(period: PERIOD, hotel: HOTEL, room: ROOM)
  end

  test "writes fetched rates to cache" do
    with_memory_cache do
      stub_rate_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
        run_service(@key)
        assert_equal "150.00", RateCache.instance.read(@key)[:rate]
      end
    end
  end

  test "sets result after run" do
    with_memory_cache do
      stub_rate_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
        service = run_service(@key)
        assert_equal PricingOutcome::SUCCESS, service.result[:outcome]
        assert_equal 1, service.result[:rates].size
        assert_empty service.result[:failed_rates]
      end
    end
  end

  test "does not write to cache when fetch fails" do
    with_memory_cache do
      mock = OpenStruct.new(success?: false, code: "503", body: {}.to_json)
      RateApiClient.stub(:bulk_get_rates, mock) do
        run_service(@key)
        assert_nil RateCache.instance.read(@key)
      end
    end
  end

  test "writes only successful rates to cache on partial success" do
    key2 = RateKey.new(period: PERIOD, hotel: HOTEL, room: "BooleanTwin")

    with_memory_cache do
      stub_rate_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
        service = run_service(@key, key2)
        assert_equal "150.00", RateCache.instance.read(@key)[:rate]
        assert_nil RateCache.instance.read(key2)
        assert_equal 1, service.result[:failed_rates].size
      end
    end
  end

  private

  def run_service(*keys)
    service = RateRefreshService.new(keys: keys)
    service.run
    service
  end

  def stub_rate_api(rates:, &block)
    mock = OpenStruct.new(success?: true, code: "200", body: { "rates" => rates }.to_json)
    RateApiClient.stub(:bulk_get_rates, mock, &block)
  end

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end
end
