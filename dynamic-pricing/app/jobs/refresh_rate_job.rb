class RefreshRateJob < ApplicationJob
  queue_as :default

  INTERVAL = ENV.fetch("REFRESH_RATE_JOB_INTERVAL_SECONDS", 30).to_i.seconds
  CACHED_RATE_PRE_EXPIRY_WINDOW = ENV.fetch("REFRESH_RATE_JOB_CACHED_RATE_PRE_EXPIRY_WINDOW_SECONDS", 60).to_i.seconds

  ALL_RATE_KEYS = PricingParams::VALID_PERIODS.flat_map do |period|
    PricingParams::VALID_HOTELS.flat_map do |hotel|
      PricingParams::VALID_ROOMS.map { |room| RateKey.new(period: period, hotel: hotel, room: room) }
    end
  end.freeze

  def perform
    to_refresh = ALL_RATE_KEYS.select { |key| needs_refresh?(key) }
    RateRefreshService.new(keys: to_refresh).run if to_refresh.any?
  ensure
    self.class.set(wait: INTERVAL).perform_later
  end

  private

  def needs_refresh?(key)
    # Only pre-cache a rate if it's stale (expiring soon, or already expired) AND
    # it's been accessed recently, reflecting recent demand

    RateCache.instance.stale?(key, expiry_buffer: CACHED_RATE_PRE_EXPIRY_WINDOW) &&
      RateCache.instance.recently_requested?(key)
  end
end
