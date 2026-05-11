require "test_helper"

class RefreshRateJobTest < ActiveSupport::TestCase
  PERIOD = "Summer"
  HOTEL = "FloatingPointResort"
  ROOM = "SingletonRoom"

  setup do
    @key = RateKey.new(period: PERIOD, hotel: HOTEL, room: ROOM)
    @job = RefreshRateJob.new
  end

  test "ALL_RATE_KEYS contains all combinations" do
    expected = PricingParams::VALID_PERIODS.size *
               PricingParams::VALID_HOTELS.size *
               PricingParams::VALID_ROOMS.size
    assert_equal expected, RefreshRateJob::ALL_RATE_KEYS.size
  end

  test "does not run refresh when no keys need refresh" do
    with_memory_cache do
      RateRefreshService.stub(:new, ->(**) { raise "should not be called" }) do
        @job.perform
      end
    end
  end

  # STALE_AND_RECENTLY_REQUESTED policy

  test "STALE_AND_RECENTLY_REQUESTED: refreshes stale keys that have been recently requested" do
    with_memory_cache do
      with_refresh_policy(RefreshRateJob::RefreshPolicy::STALE_AND_RECENTLY_REQUESTED) do
        RateCache.instance.write(@key, "150.00")
        RateCache.instance.record_access([@key])

        refreshed_keys = nil
        stub_refresh_service = ->(keys:) { refreshed_keys = keys; OpenStruct.new(run: nil) }

        travel_to (RateCache::CACHE_TTL - RefreshRateJob::CACHED_RATE_PRE_EXPIRY_WINDOW + 1.second).from_now do
          RateRefreshService.stub(:new, stub_refresh_service) { @job.perform }
        end

        assert_equal [@key], refreshed_keys
      end
    end
  end

  test "STALE_AND_RECENTLY_REQUESTED: does not refresh stale key that has not been recently requested" do
    with_memory_cache do
      with_refresh_policy(RefreshRateJob::RefreshPolicy::STALE_AND_RECENTLY_REQUESTED) do
        RateCache.instance.write(@key, "150.00")

        RateRefreshService.stub(:new, ->(**) { raise "should not be called" }) do
          travel_to (RateCache::CACHE_TTL - RefreshRateJob::CACHED_RATE_PRE_EXPIRY_WINDOW + 1.second).from_now do
            @job.perform
          end
        end
      end
    end
  end

  test "STALE_AND_RECENTLY_REQUESTED: does not refresh recently requested key that is not yet stale" do
    with_memory_cache do
      with_refresh_policy(RefreshRateJob::RefreshPolicy::STALE_AND_RECENTLY_REQUESTED) do
        RateCache.instance.write(@key, "150.00")
        RateCache.instance.record_access([@key])

        RateRefreshService.stub(:new, ->(**) { raise "should not be called" }) { @job.perform }
      end
    end
  end

  # STALE policy

  test "STALE: refreshes stale key even without recent activity" do
    with_memory_cache do
      with_refresh_policy(RefreshRateJob::RefreshPolicy::STALE) do
        with_all_rate_keys([@key]) do
          RateCache.instance.write(@key, "150.00")

          refreshed_keys = nil
          stub_refresh_service = ->(keys:) { refreshed_keys = keys; OpenStruct.new(run: nil) }

          travel_to (RateCache::CACHE_TTL - RefreshRateJob::CACHED_RATE_PRE_EXPIRY_WINDOW + 1.second).from_now do
            RateRefreshService.stub(:new, stub_refresh_service) { @job.perform }
          end

          assert_equal [@key], refreshed_keys
        end
      end
    end
  end

  test "STALE: does not refresh key that is not yet stale" do
    with_memory_cache do
      with_refresh_policy(RefreshRateJob::RefreshPolicy::STALE) do
        with_all_rate_keys([@key]) do
          RateCache.instance.write(@key, "150.00")

          RateRefreshService.stub(:new, ->(**) { raise "should not be called" }) { @job.perform }
        end
      end
    end
  end

  test "re-enqueues itself after perform" do
    with_memory_cache do
      enqueued = false
      RefreshRateJob.stub(:set, ->(**) { OpenStruct.new(perform_later: enqueued = true) }) do
        @job.perform
      end
      assert enqueued
    end
  end

  test "re-enqueues itself even when refresh raises" do
    with_memory_cache do
      RateCache.instance.write(@key, "150.00")
      RateCache.instance.record_access([@key])

      enqueued = false
      RefreshRateJob.stub(:set, ->(**) { OpenStruct.new(perform_later: enqueued = true) }) do
        travel_to (RateCache::CACHE_TTL - RefreshRateJob::CACHED_RATE_PRE_EXPIRY_WINDOW + 1.second).from_now do
          RateRefreshService.stub(:new, ->(**) { raise "boom" }) do
            assert_raises(RuntimeError) { @job.perform }
          end
        end
      end

      assert enqueued
    end
  end

  private

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  def with_all_rate_keys(keys)
    original = RefreshRateJob::ALL_RATE_KEYS
    RefreshRateJob.send(:remove_const, :ALL_RATE_KEYS)
    RefreshRateJob.const_set(:ALL_RATE_KEYS, keys.freeze)
    yield
  ensure
    RefreshRateJob.send(:remove_const, :ALL_RATE_KEYS)
    RefreshRateJob.const_set(:ALL_RATE_KEYS, original)
  end

  def with_refresh_policy(policy)
    original = RefreshRateJob::REFRESH_POLICY
    RefreshRateJob.send(:remove_const, :REFRESH_POLICY)
    RefreshRateJob.const_set(:REFRESH_POLICY, policy)
    yield
  ensure
    RefreshRateJob.send(:remove_const, :REFRESH_POLICY)
    RefreshRateJob.const_set(:REFRESH_POLICY, original)
  end
end
