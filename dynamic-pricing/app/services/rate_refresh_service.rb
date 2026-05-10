class RateRefreshService
  include SemanticLogger::Loggable
  attr_reader :result

  def initialize(keys:)
    @rate_api_fetcher = RateApiFetcher.new(rate_keys: keys)
  end

  def run
    logger.info("Rate refresh started", event: "rates_refresh_started")

    @result = @rate_api_fetcher.fetch

    rates = @result[:rates]
    failed_rates = @result[:failed_rates]

    if rates.any?
      cache_entries = rates.to_h { |r| [RateKey.from(r), r[:rate]] }
      RateCache.instance.write_multi(cache_entries)
      logger.info("Rate refresh complete", event: "rates_refreshed", count: rates.size, rates: rates)
    end

    if failed_rates.any?
      logger.warn("Rate refresh failures", event: "rate_refresh_failures", count: failed_rates.size, rates: failed_rates)
    end
  end
end
