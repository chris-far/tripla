class RefreshRateJob < ApplicationJob
  include SemanticLogger::Loggable
  queue_as :default

  module RefreshPolicy
    STALE = "stale"
    STALE_AND_RECENTLY_REQUESTED = "stale_and_recently_requested"
  end

  REFRESH_POLICY = ENV.fetch("REFRESH_RATE_JOB_REFRESH_POLICY", RefreshPolicy::STALE_AND_RECENTLY_REQUESTED)
  INTERVAL = ENV.fetch("REFRESH_RATE_JOB_INTERVAL_SECONDS", 30).to_i.seconds
  CACHED_RATE_PRE_EXPIRY_WINDOW = ENV.fetch("REFRESH_RATE_JOB_CACHED_RATE_PRE_EXPIRY_WINDOW_SECONDS", 60).to_i.seconds

  ALL_RATE_KEYS = PricingParams::VALID_PERIODS.flat_map do |period|
    PricingParams::VALID_HOTELS.flat_map do |hotel|
      PricingParams::VALID_ROOMS.map { |room| RateKey.new(period: period, hotel: hotel, room: room) }
    end
  end.freeze

  def perform
    to_refresh = ALL_RATE_KEYS.select { |key| needs_refresh?(key) }

    if to_refresh.any?
      logger.info("Stale rates detected, proceeding to refresh", count: to_refresh.size, rates: to_refresh.map(&:to_h))
      RateRefreshService.new(keys: to_refresh).run
    end
  ensure
    self.class.set(wait: INTERVAL).perform_later
  end

  private

  def needs_refresh?(key)
    case REFRESH_POLICY
    when RefreshPolicy::STALE then stale?(key)
    when RefreshPolicy::STALE_AND_RECENTLY_REQUESTED then stale_and_recently_requested(key)
    else raise "Invalid refresh policy: #{REFRESH_POLICY}"
    end
  end

  def stale_and_recently_requested(key)
    stale?(key) && RateCache.instance.recently_requested?(key)
  end

  def stale?(key)
    # Expiring within the expiry_buffer window or already expired
    RateCache.instance.stale?(key, expiry_buffer: CACHED_RATE_PRE_EXPIRY_WINDOW)
  end
end
