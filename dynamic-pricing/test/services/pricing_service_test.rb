require "test_helper"

class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  PERIOD = "Summer"
  HOTEL = "FloatingPointResort"
  ROOM = "SingletonRoom"

  setup do
    @params = PricingParams.new(period: PERIOD, hotel: HOTEL, room: ROOM)
    @key = RateKey.new(period: PERIOD, hotel: HOTEL, room: ROOM)
  end

  test "returns success with cached rate" do
    with_memory_cache do
      RateCache.instance.write(@key, "150.00")
      service = run_service(@params)
      assert_equal PricingOutcome::SUCCESS, service.outcome
      assert service.valid?
      assert_nil service.message
      assert_equal 1, service.rates.size
      assert_equal "150.00", service.rates.first[:rate]
      assert_equal "success", service.rates.first[:status]
      assert_not_nil service.rates.first[:valid_until]
    end
  end

  test "fetches and caches rate on cache miss" do
    with_memory_cache do
      stub_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
        service = run_service(@params)
        assert_equal PricingOutcome::SUCCESS, service.outcome
        assert service.valid?
        assert_nil service.message
        assert_equal "150.00", service.rates.first[:rate]
      end
    end
  end

  test "returns partial_success when some rates cannot be fetched" do
    params2 = PricingParams.new(period: PERIOD, hotel: HOTEL, room: "BooleanTwin")

    with_memory_cache do
      stub_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
        service = run_service([@params, params2])
        assert_equal PricingOutcome::PARTIAL_SUCCESS, service.outcome
        assert service.valid?
        assert_equal "Some rates are currently unavailable", service.message
        assert_equal 1, service.rates.count { |r| r[:status] == "success" }
        assert_equal 1, service.rates.count { |r| r[:status] == "error" }
      end
    end
  end

  test "returns failure when no rates can be fetched" do
    with_memory_cache do
      stub_api(rates: [{ "period" => "Winter", "hotel" => HOTEL, "room" => ROOM, "rate" => "100.00" }]) do
        service = run_service(@params)
        assert_equal PricingOutcome::FAILURE, service.outcome
        refute service.valid?
        assert_equal "Rates are temporarily unavailable", service.message
        assert_nil service.rates
      end
    end
  end

  test "returns error when API is unavailable" do
    with_memory_cache do
      mock = OpenStruct.new(success?: false, code: "503", body: {}.to_json)
      RateApiClient.stub(:bulk_get_rates, mock) do
        service = run_service(@params)
        assert_equal PricingOutcome::ERROR, service.outcome
        refute service.valid?
        assert_equal "Pricing system is temporarily unavailable", service.message
        assert_nil service.rates
      end
    end
  end

  test "records access on cache hit" do
    with_memory_cache do
      RateCache.instance.write(@key, "150.00")
      run_service(@params)
      assert RateCache.instance.recently_requested?(@key), "Expected access to be recorded on cache hit"
    end
  end

  test "records access on cache miss after refresh" do
    with_memory_cache do
      stub_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
        run_service(@params)
        assert RateCache.instance.recently_requested?(@key), "Expected access to be recorded after cache miss and refresh"
      end
    end
  end

  test "deduplicates identical pricing params" do
    with_memory_cache do
      stub_api(rates: [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }]) do
        service = run_service([@params, @params])
        assert_equal 1, service.rates.size
      end
    end
  end

  test "uses cached rate on second request without hitting API" do
    with_memory_cache do
      call_count = 0
      RateApiClient.stub(:bulk_get_rates, ->(**_) { call_count += 1; success_response }) do
        run_service(@params)
        run_service(@params)
        assert_equal 1, call_count
      end
    end
  end

  private

  def run_service(params)
    service = Api::V1::PricingService.new(pricing_params: Array(params))
    service.run
    service
  end

  def stub_api(rates:, &block)
    mock = OpenStruct.new(success?: true, code: "200", body: { "rates" => rates }.to_json)
    RateApiClient.stub(:bulk_get_rates, mock, &block)
  end

  def success_response
    OpenStruct.new(
      success?: true, code: "200",
      body: { "rates" => [{ "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }] }.to_json
    )
  end

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end
end
