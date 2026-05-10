require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  VALID_PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze

  test "returns rate for valid parameters" do
    stub_rate_api(rates: [{ "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => "15000" }]) do
      get api_v1_pricing_url, params: VALID_PARAMS
      assert_response :success
      json = JSON.parse(@response.body)
      assert_equal "success", json["outcome"]
      assert_equal "15000", json["rates"].first["rate"]
      assert_equal "success", json["rates"].first["status"]
    end
  end

  test "returns bad_gateway when rate API fails" do
    mock = OpenStruct.new(success?: false, code: "400", body: { "error" => "Rate not found" }.to_json)
    RateApiClient.stub(:bulk_get_rates, mock) do
      get api_v1_pricing_url, params: VALID_PARAMS
      assert_response :bad_gateway
      json = JSON.parse(@response.body)
      assert_equal "error", json["outcome"]
    end
  end

  test "returns bad_request without any parameters" do
    get api_v1_pricing_url
    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert_equal "error", json["outcome"]
    assert json["errors"].any? { |e| e.include?("blank") }
  end

  test "returns bad_request for empty parameters" do
    get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }
    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert json["errors"].any? { |e| e.include?("blank") }
  end

  test "returns bad_request for invalid period" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(period: "summer-2024")
    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert json["errors"].any? { |e| e.include?("Period must be one of") }
  end

  test "returns bad_request for invalid hotel" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(hotel: "InvalidHotel")
    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert json["errors"].any? { |e| e.include?("Hotel must be one of") }
  end

  test "returns bad_request for invalid room" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(room: "InvalidRoom")
    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert json["errors"].any? { |e| e.include?("Room must be one of") }
  end

  test "serves cached rate on subsequent requests" do
    with_memory_cache do
      call_count = 0
      RateApiClient.stub(:bulk_get_rates, ->(**_) { call_count += 1; success_response }) do
        2.times do
          get api_v1_pricing_url, params: VALID_PARAMS
          assert_response :success
        end
        assert_equal 1, call_count
      end
    end
  end

  test "fetches fresh rate after cache TTL expires" do
    with_memory_cache do
      call_count = 0
      RateApiClient.stub(:bulk_get_rates, ->(**_) { call_count += 1; success_response }) do
        get api_v1_pricing_url, params: VALID_PARAMS
        assert_equal 1, call_count

        travel_to 7.minutes.from_now do
          get api_v1_pricing_url, params: VALID_PARAMS
          assert_equal 2, call_count
        end
      end
    end
  end

  test "concurrent requests on cold cache only hit the API once" do
    call_count = 0
    call_count_mutex = Mutex.new

    slow_stub = ->(**_) {
      sleep 0.05
      call_count_mutex.synchronize { call_count += 1 }
      success_response
    }

    with_memory_cache do
      RateApiClient.stub(:bulk_get_rates, slow_stub) do
        threads = 5.times.map do
          Thread.new { Api::V1::PricingService.new(pricing_params: [PricingParams.new(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")]).run }
        end
        threads.each(&:join)
        assert_equal 1, call_count, "Expected 1 API call but got #{call_count} — thundering herd not prevented"
      end
    end
  end

  private

  def stub_rate_api(rates:, &block)
    mock = OpenStruct.new(success?: true, code: "200", body: { "rates" => rates }.to_json)
    RateApiClient.stub(:bulk_get_rates, mock, &block)
  end

  def success_response
    OpenStruct.new(
      success?: true, code: "200",
      body: { "rates" => [{ "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => "15000" }] }.to_json
    )
  end

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end
end
