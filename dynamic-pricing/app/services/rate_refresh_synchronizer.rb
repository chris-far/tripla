# This class pulls concurrency synchronization logic out of the RateRefreshService,
# helping to keep it decoupled from actual business logic
class RateRefreshSynchronizer
  include RateHashBuilder
  # One-shot result container. Awaiting threads block on `await` until the fetching
  # thread calls `fulfill`, then receives the value directly
  class Promise
    def initialize
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @value = nil
      @fulfilled = false
    end

    def fulfill(value)
      @mutex.synchronize do
        @value = value
        @fulfilled = true
        @cond.broadcast
      end
    end

    def await
      @mutex.synchronize do
        @cond.wait(@mutex) until @fulfilled
        @value
      end
    end
  end

  MUTEXES = Hash.new { |h, k| h[k] = Mutex.new }
  MUTEXES_LOCK = Mutex.new
  RESULTS = {}  # cache_key => Promise (current in-flight promise for that key)

  def self.synchronize(keys, &block)
    new(keys).synchronize(&block)
  end

  def initialize(keys)
    @keys = keys
  end

  # Yields the subset of keys this thread won the lock for.
  # The block must return { rates:, failed_rates:, outcome: }.
  # Awaiting threads hold a direct Promise reference captured at partition time,
  # so they are immune to RESULTS being updated by a later run before they read it.
  def synchronize
    to_fetch, to_await = partition_keys_by_lock

    fetched_rates, fetched_failed, fetch_outcome =
      if to_fetch.any?
        begin
          result = yield(to_fetch.keys)
          rates_by_key = result[:rates].index_by { |r| RateKey.from(r).cache_key }
          [result[:rates], result[:failed_rates], result[:outcome]]
        ensure
          # Fulfill promises before releasing locks. rates_by_key is nil on exception, so
          # any key absent from the result (including on exception) fulfills with nil => failure.
          to_fetch.each do |key, (mutex, promise)|
            promise.fulfill(rates_by_key && rates_by_key[key.cache_key])
            mutex.unlock
          end
        end
      else
        [[], [], PricingOutcome::SUCCESS]
      end

    awaited_rates, awaited_failed = to_await.any? ? await_and_collect(to_await) : [[], []]

    { rates: fetched_rates + awaited_rates, failed_rates: fetched_failed + awaited_failed, fetch_outcome: fetch_outcome }
  end

  private

  def partition_keys_by_lock
    to_fetch = {}
    to_await = {}
    @keys.each do |key|
      # Both the try_lock and the RESULTS read/write happen under MUTEXES_LOCK, so the
      # promise is always stored before any other thread can observe the lock as taken.
      MUTEXES_LOCK.synchronize do
        mutex = MUTEXES[key.cache_key]
        if mutex.try_lock
          promise = Promise.new
          RESULTS[key.cache_key] = promise
          to_fetch[key] = [mutex, promise]
        else
          to_await[key] = RESULTS[key.cache_key]
        end
      end
    end
    [to_fetch, to_await]
  end

  def await_and_collect(to_await)
    rates = []
    failed = []
    to_await.each do |key, promise|
      rate = promise.await
      rate ? rates << rate : failed << to_rate_hash(key, status: RateStatus::ERROR, error: "Rate not available")
    end
    [rates, failed]
  end
end
