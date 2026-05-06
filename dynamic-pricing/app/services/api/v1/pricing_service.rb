module Api::V1
  class PricingService < BaseService
    include SemanticLogger::Loggable

    MAX_RETRIES = 1
    MAX_RETRY_DELAY = 30
    RATE_CACHE_TTL = 0.01.minutes
    RETRYABLE_STATUS_CODES = [408, 429, 500, 502, 503, 504].freeze
    RETRYABLE_EXCEPTIONS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET
    ].freeze

    def initialize(request:)
      @request = request
    end

    def run
      logger.tagged(period: @request.period, hotel: @request.hotel, room: @request.room) do
        get_pricing
      end
    end

    private

    def get_pricing
      cached = Rails.cache.read(rate_cache_key)

      if cached
        @result = cached[:rate]
        logger.info("Returning cached rate", event: "cache_hit", rate: cached[:rate], metric: "pricing.cache.hits")
        return
      end

      logger.info("No cached value found", event: "cache_miss", metric: "pricing.cache.misses")
      result = fetch_rate_with_retries

      unless result[:success]
        @errors = [result[:error] || 'We\'re sorry, there was a problem retrieving your rates. Please try again later.']
        return
      end

      Rails.cache.write(rate_cache_key, { rate: result[:rate] }, expires_in: RATE_CACHE_TTL)
      @result = result[:rate]
      logger.info("Returning freshly cached rate", event: "rate_cached", rate: result[:rate])
    end

    def rate_cache_key
      "pricing/rate/#{@request.period}/#{@request.hotel}/#{@request.room}"
    end

    def fetch_rate_with_retries
      max_attempts = MAX_RETRIES + 1
      retries = 0

      max_attempts.times do
        result = fetch_and_extract_rate

        if result[:success]
          logger.info("Successfully retrieved rate from Rates API", event: "rate_api_fetch_success", metric: "pricing.api.successes", rate: result[:rate])
          return result
        end

        if retries < MAX_RETRIES && result[:retryable]
          retries += 1
          delay_seconds = retry_delay(retries)

          logger.warn("Retrying Rates API call", event: "rate_api_fetch_retry", attempt: retries+1, max_attempts: max_attempts, delay_seconds: delay_seconds.round(2), reason: result[:reason])
          sleep delay_seconds
          next
        end

        logger.warn("Failed to retrieve rates from Rates API", event: "rate_api_fetch_failed", metric: "pricing.api.failures", attempts: retries+1, max_attempts: max_attempts, reason: result[:reason])
        return result
      end
    end

    def retry_delay(retries)
      base_delay = 0.5
      exponential_delay = 2**(retries-1)
      jitter = rand(0.5..1.5).to_f
      actual_delay = base_delay * exponential_delay + jitter
      [actual_delay, MAX_RETRY_DELAY].min
    end

    def fetch_and_extract_rate
      begin
        response = nil
        logger.measure_info("Fetching rate from Rates API", payload: {event: "rate_api_fetch"}, metric: "pricing.api.fetch_duration") do
          response = RateApiClient.get_rate(period: @request.period, hotel: @request.hotel, room: @request.room)
        end
      rescue *RETRYABLE_EXCEPTIONS => e
        return {
          retryable: true,
          reason: "Rates API threw an exception: #{e.message}"
        }
      end

      begin
        parsed_body = JSON.parse(response.body)
      rescue JSON::ParserError => e
        return{
          retryable: false,
          reason: "Rates API returned invalid JSON: #{e.message}"
        }
      end

      error = parsed_body['error']
      error_with_fallback = error || 'Unknown error'

      status_code = response.code&.to_i
      if RETRYABLE_STATUS_CODES.include?(status_code)
        return {
          retryable: true,
          reason: "Rates API returned status code #{status_code}: #{error_with_fallback}",
          error: error
        }
      end

      unless response.success?
        return {
          retryable: false,
          reason: "Rates API returned unsuccessful response: #{error_with_fallback}",
          error: error
        }
      end

      if parsed_body.key?('status') && parsed_body['status'] == 'error'
        message = parsed_body['message'] || error_with_fallback
        return {
          retryable: true,
          reason: "Rates API returned error: #{message}",
          error: error
        }
      end

      rates = parsed_body['rates']
      unless rates.is_a?(Array) && rates.any?
        return {
          retryable: true,
          reason: "Rates API did not return any rates: #{error_with_fallback}",
          error: error
        }
      end

      rate = extract_rate(rates)
      if rate.nil?
        return {
          retryable: true,
          reason: "Rates API returned a null rate",
          error: error
        }
      end

      {
        success: true,
        rate: rate
      }
    end

    def extract_rate(rates)
      matched_rate = rates.detect do |rate|
        rate['period'] == @request.period &&
          rate['hotel'] == @request.hotel &&
          rate['room'] == @request.room
      end

      matched_rate&.dig('rate')
    end
  end
end
