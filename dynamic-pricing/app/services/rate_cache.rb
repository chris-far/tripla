require "singleton"

class RateCache
  include Singleton
  CACHE_TTL = ENV.fetch("RATE_CACHE_TTL_SECONDS", 300).to_i.seconds
  ACTIVE_REQUEST_WINDOW = ENV.fetch("RATE_CACHE_ACTIVE_REQUEST_WINDOW_SECONDS", 600).to_i.seconds

  def read(key)
    read_multi([key])[key]
  end

  def read_multi(keys)
    keyed = keys.index_by { |key| rate_key(key) }
    found = Rails.cache.read_multi(*keyed.keys)
    found.each_with_object({}) { |(string_key, cached), h| h[keyed[string_key]] = { rate: cached[:rate], valid_until: cached[:valid_until] } if cached }
  end

  def record_access(keys, window: ACTIVE_REQUEST_WINDOW)
    entries = keys.each_with_object({}) { |key, h| h[access_key(key)] = true }
    Rails.cache.write_multi(entries, expires_in: window)
  end

  def write(key, rate)
    write_multi({ key => rate })
  end

  def write_multi(hash)
    fetched_at = Time.now
    valid_until = fetched_at + CACHE_TTL
    entries = hash.each_with_object({}) { |(key, rate), h| h[rate_key(key)] = { rate: rate, fetched_at: fetched_at, valid_until: valid_until } }
    Rails.cache.write_multi(entries, expires_in: CACHE_TTL)
  end

  def stale?(key, expiry_buffer:)
    cached = Rails.cache.read(rate_key(key))
    cached.nil? || cached[:valid_until] <= Time.now + expiry_buffer
  end

  def recently_requested?(key)
    Rails.cache.read(access_key(key)).present?
  end

  private

  def rate_key(key)
    "pricing/rate/#{key.cache_key}"
  end

  def access_key(key)
    "pricing/access/#{key.cache_key}"
  end
end
