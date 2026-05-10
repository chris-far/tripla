module Api::V1
  class PricingService < BaseService
    include SemanticLogger::Loggable
    attr_reader :outcome, :message, :rates

UNSUCCESSFUL_OUTCOMES = [PricingOutcome::FAILURE, PricingOutcome::ERROR].freeze

    def initialize(pricing_params:)
      @keys = Array(pricing_params).map { |p| RateKey.new(period: p.period, hotel: p.hotel, room: p.room) }.uniq
    end

    def run
      logger.tagged(*@keys.map { |k| { period: k.period, hotel: k.hotel, room: k.room } }) do
        get_pricing
      end
    end

    def valid?
      super && !UNSUCCESSFUL_OUTCOMES.include?(@outcome)
    end

    private

    def get_pricing
      cached_rates = read_from_cache_and_record_access(@keys)
      logger.info("Cache hits", event: "cache_hit", count: cached_rates.size, metric: "pricing.cache.hits") if cached_rates.any?

      missing_keys = @keys - cached_rates.keys
      if missing_keys.empty?
        @outcome = PricingOutcome::SUCCESS
        @rates = to_rates_hash(cached_rates)
        return
      end

      logger.info("Cache misses", event: "cache_miss", count: missing_keys.size, metric: "pricing.cache.misses")
      refresh_result = refresh_and_cache_missing_rates(missing_keys, cached_rates)

      @outcome = get_outcome(cached_rates, refresh_result[:outcome])
      @message = get_message(@outcome)
      @rates = to_rates_hash(cached_rates) + refresh_result[:failed_rates] if valid?
    end

    def refresh_and_cache_missing_rates(missing_keys, cached_rates)
      refresh_service = RateRefreshService.new(keys: missing_keys)
      refresh_service.run

      refreshed_rates = refresh_service.result[:rates]
      if refreshed_rates.any?
        success_keys = refreshed_rates.map { |r| RateKey.from(r) }
        cache_entries = read_from_cache_and_record_access(success_keys)
        cached_rates.merge!(cache_entries)
      end

      refresh_service.result
    end

    def read_from_cache_and_record_access(keys)
      cache_entries = RateCache.instance.read_multi(keys)
      RateCache.instance.record_access(keys)
      cache_entries
    end

    def get_outcome(results, refresh_outcome)
      missing = @keys - results.keys

      if missing.empty?
        PricingOutcome::SUCCESS
      elsif results.any?
        PricingOutcome::PARTIAL_SUCCESS
      else
        refresh_outcome
      end
    end

    def get_message(outcome)
        case outcome
        when PricingOutcome::PARTIAL_SUCCESS then "Some rates are currently unavailable"
        when PricingOutcome::FAILURE then "Rates are temporarily unavailable"
        when PricingOutcome::ERROR then "Pricing system is temporarily unavailable"
        else nil
        end
    end

    def to_rates_hash(cached_rates)
      cached_rates.map do |key, entry|
        { period: key.period, hotel: key.hotel, room: key.room, rate: entry[:rate], status: "success", valid_until: entry[:valid_until] }
      end
    end
  end
end
