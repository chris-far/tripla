class RateApiFetcher
  include SemanticLogger::Loggable
  include RateHashBuilder

  MAX_RETRIES = ENV.fetch("RATE_API_MAX_RETRIES", 2).to_i
  MAX_RETRY_DELAY = ENV.fetch("RATE_API_MAX_RETRY_DELAY_SECONDS", 30).to_i
  RETRYABLE_STATUS_CODES = [408, 429, 500, 502, 503, 504].freeze
  RETRYABLE_EXCEPTIONS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET
  ].freeze

  def initialize(rate_keys:)
    @rate_keys = rate_keys
  end

  def fetch
    fetch_with_retries
  end

  private

  def fetch_with_retries
    keys_to_fetch = @rate_keys
    accumulated_rates = []
    max_attempts = MAX_RETRIES + 1
    retries = 0
    result = nil

    max_attempts.times do
      result = fetch_and_extract_rates(keys_to_fetch)
      accumulated_rates.concat(result[:rates] || [])

      if result[:success]
        logger.info("Successfully retrieved rates from Rates API", event: "rate_api_fetch_success",
                    metric: "pricing.rate_api.success", count: accumulated_rates.size)
        return to_result(result[:outcome], accumulated_rates)
      end

      keys_to_fetch = result[:failed_keys] || keys_to_fetch
      break unless result[:retryable] && retries < MAX_RETRIES

      retries += 1
      delay = retry_delay(retries)
      logger.warn("Retrying Rates API call", event: "rate_api_fetch_retry",
                  attempt: retries + 1, max_attempts: max_attempts, delay_seconds: delay.round(2),
                  reason: result[:reason], detail: result[:detail], count: keys_to_fetch.size)
      sleep delay
    end

    failed_rates = keys_to_fetch.map { |key| to_rate_hash(key, error: "Rate not available", status: "error") }
    final_outcome = accumulated_rates.any? ? PricingOutcome::PARTIAL_SUCCESS : result[:outcome]

    logger.error("Failed to retrieve rates from Rates API", event: "rate_api_fetch_failed",
                metric: "pricing.rate_api.failure", attempts: retries + 1, max_attempts: max_attempts,
                count: failed_rates.size, reason: result[:reason], detail: result[:detail])

    to_result(final_outcome, accumulated_rates, failed_rates)
  end

  def fetch_and_extract_rates(rate_keys)
    response = call_api(rate_keys)
    return response if response[:error]

    parsed = parse_response(response[:response])
    return parsed if parsed[:error]

    extract_from_body(rate_keys, parsed[:body])
  end

  def call_api(rate_keys)
    response = nil
    logger.measure_info("Fetching rates from Rates API",
                        payload: { event: "rate_api_fetch", count: rate_keys.size },
                        metric: "pricing.rate_api.fetch_duration") do
      response = RateApiClient.bulk_get_rates(bulk_request: rate_keys.map(&:to_h))
    end
    { response: response }
  rescue *RETRYABLE_EXCEPTIONS => e
    { error: true, retryable: true, reason: "Rates API threw an exception", detail: exception_detail(e), outcome: PricingOutcome::ERROR }
  end

  def parse_response(response)
    status_code = response.code&.to_i
    body = JSON.parse(response.body)
    detail = body["message"] || body["error"]

    if RETRYABLE_STATUS_CODES.include?(status_code)
      return { error: true, retryable: true, reason: "Rates API returned status code #{status_code}", detail: detail, outcome: PricingOutcome::ERROR }
    end

    unless response.success?
      return { error: true, retryable: false, reason: "Rates API returned unsuccessful response", detail: detail || "Status code #{status_code}", outcome: PricingOutcome::ERROR }
    end

    if body["status"] == "error"
      return { error: true, retryable: true, reason: "Rates API returned a status of 'error'", detail: detail, outcome: PricingOutcome::ERROR }
    end

    { body: body }
  rescue JSON::ParserError => e
    { error: true, retryable: false, reason: "Rates API returned invalid JSON", detail: exception_detail(e), outcome: PricingOutcome::ERROR }
  end

  def exception_detail(e)
    "#{e.class}: #{e.message}"
  end

  def extract_from_body(rate_keys, body)
    raw_rates = body["rates"]
    unless raw_rates.is_a?(Array) && raw_rates.any?
      return { retryable: true, reason: "Rates API did not return any rates", detail: "No 'rates' array found in JSON body",
               outcome: PricingOutcome::ERROR }
    end

    extracted = extract_rates(rate_keys, raw_rates)
    failed_keys = extracted[:failed_keys]

    if failed_keys.any?
      outcome = extracted[:rates].any? ? PricingOutcome::PARTIAL_SUCCESS : PricingOutcome::FAILURE
      return { retryable: true, rates: extracted[:rates], failed_keys: failed_keys,
               reason: "Rates API returned with missing or nil rates", detail: failed_keys.map(&:to_h), outcome: outcome }
    end

    { success: true, rates: extracted[:rates], outcome: PricingOutcome::SUCCESS }
  end

  def extract_rates(rate_keys, raw_rates)
    rates = []
    failed_keys = []

    rate_keys.each do |key|
      matched = raw_rates.find { |r| r["period"] == key.period && r["hotel"] == key.hotel && r["room"] == key.room }

      if matched && !matched["rate"].nil?
        rates << to_rate_hash(key, rate: matched["rate"], status: "success")
      else
        failed_keys << key
      end
    end

    { rates: rates, failed_keys: failed_keys }
  end

  def to_result(outcome, rates, failed_rates = [])
    { outcome: outcome, rates: rates, failed_rates: failed_rates }
  end

  def retry_delay(retries)
    base_delay = 0.5
    exponential_delay = 2 ** (retries - 1)
    jitter = rand(0.5..1.5).to_f
    actual_delay = base_delay * exponential_delay + jitter
    [actual_delay, MAX_RETRY_DELAY].min
  end
end
