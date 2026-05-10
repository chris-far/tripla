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

  test "concurrent refreshes where the API fails: all threads receive failure, not a stale result" do
    call_count = 0
    call_count_mutex = Mutex.new

    slow_failing_stub = ->(**_) {
      sleep 0.05
      call_count_mutex.synchronize { call_count += 1 }
      OpenStruct.new(success?: false, code: "400", body: {}.to_json)
    }

    results = []
    results_mutex = Mutex.new

    with_memory_cache do
      RateApiClient.stub(:bulk_get_rates, slow_failing_stub) do
        threads = 20.times.map do
          Thread.new do
            service = RateRefreshService.new(keys: [@key])
            service.run
            results_mutex.synchronize { results << service.result }
          end
        end
        threads.each(&:join)
      end
    end

    assert_equal 1, call_count, "Expected 1 API call but got #{call_count}: thundering herd not prevented"
    assert_equal 20, results.size
    assert results.all? { |r| r[:rates].empty? }, "Expected no successful rates"
    assert results.all? { |r| r[:failed_rates].size == 1 }, "Expected all threads to receive the failure"
    assert_nil RateCache.instance.read(@key), "Expected nothing written to cache on failure"
  end

  test "concurrent refreshes with partial API failure: all threads receive the successful rate and the failure" do
    key2 = RateKey.new(period: PERIOD, hotel: HOTEL, room: "BooleanTwin")
    call_count = 0
    call_count_mutex = Mutex.new

    slow_partial_stub = ->(**_) {
      sleep 0.05
      call_count_mutex.synchronize { call_count += 1 }
      OpenStruct.new(
        success?: true, code: "200",
        body: { "rates" => [
          { "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" }
          # key2 intentionally omitted — triggers partial failure
        ]}.to_json
      )
    }

    results = []
    results_mutex = Mutex.new

    with_memory_cache do
      RateApiClient.stub(:bulk_get_rates, slow_partial_stub) do
        threads = 20.times.map do
          Thread.new do
            service = RateRefreshService.new(keys: [@key, key2])
            service.run
            results_mutex.synchronize { results << service.result }
          end
        end
        threads.each(&:join)
      end
    end

    # Missing keys trigger retries in the fetcher; the important assertion is that only ONE
    # thread's worth of retries occurred — not 20 threads each retrying independently.
    expected_calls = RateApiFetcher::MAX_RETRIES + 1
    assert_equal expected_calls, call_count, "Expected #{expected_calls} API calls (1 attempt + retries) but got #{call_count}: thundering herd not prevented"
    assert_equal 20, results.size
    assert results.all? { |r| r[:outcome] == PricingOutcome::PARTIAL_SUCCESS }, "Expected all threads to report partial success"
    assert results.all? { |r| r[:rates].size == 1 }, "Expected all threads to receive the one successful rate"
    assert results.all? { |r| r[:rates].any? { |rate| rate[:rate] == "150.00" } }, "Expected all threads to receive the correct rate"
    assert results.all? { |r| r[:failed_rates].size == 1 }, "Expected all threads to receive the one failure"
    assert results.all? { |r| r[:failed_rates].any? { |f| f[:room] == "BooleanTwin" } }, "Expected the correct key to be reported as failed"
  end

  test "concurrent refreshes of the same key only hit the API once and all threads receive the correct rate" do
    key2 = RateKey.new(period: PERIOD, hotel: HOTEL, room: "BooleanTwin")
    call_count = 0
    call_count_mutex = Mutex.new

    slow_stub = ->(**_) {
      sleep 0.05
      call_count_mutex.synchronize { call_count += 1 }
      OpenStruct.new(
        success?: true, code: "200",
        body: { "rates" => [
          { "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "150.00" },
          { "period" => PERIOD, "hotel" => HOTEL, "room" => "BooleanTwin", "rate" => "200.00" }
        ]}.to_json
      )
    }

    results = []
    results_mutex = Mutex.new

    with_memory_cache do
      RateApiClient.stub(:bulk_get_rates, slow_stub) do
        threads = 20.times.map do
          Thread.new do
            service = RateRefreshService.new(keys: [@key, key2])
            service.run
            results_mutex.synchronize { results << service.result }
          end
        end
        threads.each(&:join)
      end
    end

    assert_equal 1, call_count, "Expected 1 API call but got #{call_count}: thundering herd not prevented"
    assert_equal 20, results.size
    assert results.all? { |r| r[:outcome] == PricingOutcome::SUCCESS }, "Expected all threads to report success"
    assert results.all? { |r| r[:rates].size == 2 }, "Expected all threads to receive both rates"
    assert results.all? { |r| r[:failed_rates].empty? }, "Expected no failed rates"
    assert results.all? { |r| r[:rates].any? { |rate| rate[:rate] == "150.00" } }, "Expected all threads to receive correct rate for key 1"
    assert results.all? { |r| r[:rates].any? { |rate| rate[:rate] == "200.00" } }, "Expected all threads to receive correct rate for key 2"
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
