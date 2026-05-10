class RateRefreshService
  include SemanticLogger::Loggable
  attr_reader :result

  def initialize(keys:)
    @keys = keys
  end

  def run
    logger.info("Rate refresh started", event: "rates_refresh_started")

    sync = RateRefreshSynchronizer.synchronize(@keys) { |keys| refresh_rates(keys) }

    all_rates = sync[:rates]
    all_failed = sync[:failed_rates]
    outcome = derive_outcome(all_rates, all_failed, sync[:fetch_outcome])
    @result = { outcome: outcome, rates: all_rates, failed_rates: all_failed }
  end

  private

  def refresh_rates(keys)
    fetch_result = RateApiFetcher.new(rate_keys: keys).fetch
    rates = fetch_result[:rates]
    failed_rates = fetch_result[:failed_rates]

    if rates.any?
      cache_entries = rates.to_h { |r| [RateKey.from(r), r[:rate]] }
      RateCache.instance.write_multi(cache_entries)
      logger.info("Rate refresh complete", event: "rates_refreshed", count: rates.size, rates: rates)
    end

    if failed_rates.any?
      logger.warn("Rate refresh failures", event: "rate_refresh_failures", count: failed_rates.size, rates: failed_rates)
    end

    fetch_result
  end

  def derive_outcome(rates, failed_rates, fetch_outcome)
    if failed_rates.empty?
      PricingOutcome::SUCCESS
    elsif rates.any?
      PricingOutcome::PARTIAL_SUCCESS
    else
      fetch_outcome
    end
  end
end
