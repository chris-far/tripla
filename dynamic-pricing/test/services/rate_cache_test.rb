require "test_helper"

class RateCacheTest < ActiveSupport::TestCase
  PERIOD = "Summer"
  HOTEL = "FloatingPointResort"
  ROOM = "SingletonRoom"

  setup do
    @key = RateKey.new(period: PERIOD, hotel: HOTEL, room: ROOM)
    @cache = RateCache.instance
  end

  test "read returns nil for missing key" do
    with_memory_cache do
      assert_nil @cache.read(@key)
    end
  end

  test "write and read round-trips the rate" do
    with_memory_cache do
      @cache.write(@key, "150.00")
      assert_equal "150.00", @cache.read(@key)[:rate]
    end
  end

  test "read includes valid_until" do
    with_memory_cache do
      @cache.write(@key, "150.00")
      entry = @cache.read(@key)
      assert_not_nil entry[:valid_until]
      assert_in_delta RateCache::CACHE_TTL.from_now, entry[:valid_until], 1.second
    end
  end

  test "read_multi returns only found keys" do
    key2 = RateKey.new(period: PERIOD, hotel: HOTEL, room: "BooleanTwin")
    with_memory_cache do
      @cache.write(@key, "150.00")
      result = @cache.read_multi([@key, key2])
      assert_equal 1, result.size
      assert result.key?(@key)
      refute result.key?(key2)
    end
  end

  test "write_multi writes multiple rates" do
    key2 = RateKey.new(period: PERIOD, hotel: HOTEL, room: "BooleanTwin")
    with_memory_cache do
      @cache.write_multi({ @key => "150.00", key2 => "200.00" })
      assert_equal "150.00", @cache.read(@key)[:rate]
      assert_equal "200.00", @cache.read(key2)[:rate]
    end
  end

  test "stale? returns true for missing key" do
    with_memory_cache do
      assert @cache.stale?(@key, expiry_buffer: 1.minute)
    end
  end

  test "stale? returns false when rate expires after duration" do
    with_memory_cache do
      @cache.write(@key, "150.00")
      refute @cache.stale?(@key, expiry_buffer: 1.second)
    end
  end

  test "stale? returns true when rate expires within duration" do
    with_memory_cache do
      @cache.write(@key, "150.00")
      assert @cache.stale?(@key, expiry_buffer: RateCache::CACHE_TTL)
    end
  end

  test "recently_requested? returns false before record_access" do
    with_memory_cache do
      refute @cache.recently_requested?(@key)
    end
  end

  test "recently_requested? returns true after record_access" do
    with_memory_cache do
      @cache.record_access([@key])
      assert @cache.recently_requested?(@key)
    end
  end

  test "record_access expires after window" do
    with_memory_cache do
      @cache.record_access([@key], window: 1.second)
      travel_to 2.seconds.from_now do
        refute @cache.recently_requested?(@key)
      end
    end
  end

  test "cached rate expires after TTL" do
    with_memory_cache do
      @cache.write(@key, "150.00")
      travel_to (RateCache::CACHE_TTL + 1.second).from_now do
        assert_nil @cache.read(@key)
      end
    end
  end

  private

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end
end
