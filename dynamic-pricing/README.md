<div style="text-align:center">
   <img src="img/logo.svg?raw=true" width=600 style="background-color:white;" alt="Logo">
</div>

# Backend Engineering Take-Home Assignment: Dynamic Pricing Proxy

## Proposed Solution
The proposed solution uses a policy-driven pre-caching strategy: a background job refreshes rates before they expire based on a chosen refresh policy (see table below).
This approach balances the constraints of the Rates API (computationally expensive, rate-limited to 1,000 calls per day, intermittent issues), while ensuring that users do
not have to wait on long-running requests. `stale_and_recently_requested` was chosen as the default refresh policy:

<a id="refresh-policies"></a>

| Refresh Policy                 | Description                                                               |
|--------------------------------|---------------------------------------------------------------------------|
| `stale`                        | Refresh rates that are N seconds away from expiry or already expired      |
| `stale_and_recently_requested` | Refresh `stale` rates only if accessed by users within the last N seconds |

### Rationale
`stale_and_recently_requested` was chosen as the default because it scales cost with actual demand/traffic, not with the size of the parameter space (currently 36 rates). The alternative policy, `stale`, would effectively refresh all rates on a fixed interval (see [Alternative Approaches Considered](#alternative-approaches-considered--trade-offs) below).
Under the fixed-interval approach, all 36 rates are refreshed every cycle, even if only 5 rates are being actively requested, resulting in 86% of API calls being wasted. Calling the Rates API on a fixed interval works well if making wasteful calls is not an issue, or you
expect high demand for the entire parameter space at all times.

### Anticipating Failure
The Rates API fetching implementation includes robust and configurable retry logic to handle errors gracefully. For example, timeout exceptions, nil or missing rates, and transient/intermittent errors are all handled without interrupting the overall flow. 
The retry strategy uses exponential backoff with jitter to avoid overloading the upstream service. A read timeout of 10 seconds was chosen to allow for slow responses, but this value is configurable. In the case where
all retry attempts are exhausted, a descriptive error message is returned to the caller. Additionally, this design supports partial failures, where a subset of rates may fail to be processed. The output returned to the caller provides a `status` for
each rate, that signifies whether the rate was successfully processed or not (see [Sample Responses](#sample-responses) below).

### Logging
Simple structured logging using the `semantic_logger` gem is used as a starting point for observability and monitoring, supporting ingestion into centralized logging systems such as Splunk and Datadog.

<a id="alternative-approaches-considered"></a>
## Alternative Approaches Considered / Trade-offs

### Naive Caching Driven by User Requests
In this approach, the application caches rates whenever a user requests them. This approach is simple, but can suffer from degraded user experience given
the Rates API may be slow or fail intermittently. With this approach, rates may drop out of the cache and the Rates API may be called again *during*
the user's next request. Additionally, it can be more susceptible to the thundering herd problem, where concurrent requests for the same uncached rate each trigger an independent call to the Rates API. 
Pre-caching eliminates this risk, ensuring that rates are already cached before the user requests them.

### Refresh All Rates on a Fixed Interval
In this approach, all rates (36 combinations) are refreshed on a fixed interval (e.g., 4.5 minutes, before the 5 minute TTL expires). This approach is simple and
effective, ensuring that rates are always up-to-date and available to users. As the `Quota Math` below shows, even in the worst case with all retries exhausted, this approach uses 960 of the 1,000 daily calls. 
The downside of this approach is that it can be wasteful, calling the Rates API even when users are not actively requesting rates. 

#### Quota Math
The bulk endpoint accepts any number of rates in a single request, therefore, the assumption is that the quota is on a per-request basis. If the quota was measured on
a per-rate basis, it would be virtually impossible to stay under the daily 1,000 call limit.

*Worst Case - All 36 Rates Refresh on Fixed Interval of 4.5 Minutes*

`4 Periods * 3 Hotels * 3 Rooms = 36 Rate Combinations` </br>
`60 min ÷ 4.5 min/refresh  = ~13.33 refreshes/hour` </br>
`24 hours * ~13.33 calls/hour = ~320 calls/day` </br>
`320 calls/day * 3 attempts/refresh = 960 calls/day`</br></br>

Note, however, there is not much buffer, `960/1000 = 4%` of headroom. In case the TTL is reduced, rate options are expanded, etc., the daily quota can easily be exceeded.
If only 10 of 36 rates are actively requested, demand-driven costs are roughly `10/36 * 960 = ~267 calls/day`

## Technical Design and Implementation

### Key Classes

| Class                            | Responsibility                                                                                                                               |
|----------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| `PricingController`              | Handles `GET /pricing` (single) and `POST /pricing/bulk`, validates params, delegates to `PricingService`, renders JSON                      |
| `PricingService`                 | Orchestrates a pricing request: reads from cache, falls back to `RateRefreshService` to fetch and cache new results                          |
| `RateApiFetcher`                 | Calls the upstream Rates API in bulk with retry logic (exponential backoff + jitter); parses JSON and handles errors gracefully              |
| `RateCache`                      | Singleton wrapper around Rails cache, stores rates with TTL and tracks recently-accessed keys for background refresh targeting               |
| `RateRefreshService`             | Fetches a given set of keys via `RateApiFetcher` and writes fresh rates into `RateCache`; used by `RateRefreshJob` and `PricingService`      |
| `RateRefreshSynchronizer` | Synchronizes concurrent calls against the Rates API to prevent the thundering herd problem; uses per-key mutex locking to solve this problem |
| `RefreshRateJob`                 | Recurring background job: finds cached rates nearing expiry for actively-requested rates and triggers `RateRefreshService`                   |
| `RateKey`                        | Value struct (`period`, `hotel`, `room`) used as a typed cache key throughout the application                                                |

### Configuration

Key ENV vars:

| Variable | Default | Description                                                                                                                                                                                                                                                      |
|---|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `RATE_CACHE_TTL_SECONDS` | `300`   | How long a fetched rate is cached                                                                                                                                                                                                                                |
| `RATE_CACHE_ACTIVE_REQUEST_WINDOW_SECONDS` | `600`   | Window for tracking recently-requested combos                                                                                                                                                                                                                    |
| `REFRESH_RATE_JOB_REFRESH_POLICY` | `stale_and_recently_requested` | [See Refresh Policies](#refresh-policies)  |
| `REFRESH_RATE_JOB_INTERVAL_SECONDS` | `30`    | How often the background job runs                                                                                                                                                                                                                                |
| `REFRESH_RATE_JOB_CACHED_RATE_PRE_EXPIRY_WINDOW_SECONDS` | `60`    | Buffer before expiry; determines when pre-caching should occur                                                                                                                                                                                                   |
| `RATE_API_OPEN_TIMEOUT` | `2`     | Rates API open timeout                                                                                                                                                                                                                                           |
| `RATE_API_READ_TIMEOUT` | `10`    | Rates API read timeout                                                                                                                                                                                                                                           |
| `RATE_API_MAX_RETRIES` | `2`     | Rates API fetch retry attempts                                                                                                                                                                                                                                   |
| `RATE_API_MAX_RETRY_DELAY_SECONDS` | `30`    | Max backoff delay between retries                                                                                                                                                                                                                                |

## Usage of AI
AI was used to increase productivity and enrich the overall development process without blindly relying on solutions or ideas it provided.
Any code generated by AI was reviewed and well-understood before being used. Many suggestions were pushed back on or rejected outright, 
with key decisions being made independently.

Here are the main areas where AI was used:
- Pair programming, sanity checking, and iterating on implementation
- Test case generation
- Clarifying Ruby / Rails syntax 
- Writing documentation
- Refactoring
- Debugging

## Assumptions
- Quota is measured per HTTP request, not per rate combination; if it were per-rate, any bulk pre-caching strategy would be virtually impossible given 36 rates
- Traffic patterns are unknown; the proposed solution assumes traffic is irregular and not all 36 rates are requested at all times
- Expired rates should never be served to users
- The Rates API is inherently unreliable and may produce intermittent errors and/or timeouts in an unpredictable manner

<a id="sample-responses"></a>
## Sample Responses

**`SUCCESS` all rates available (HTTP 200)**
```json
{
  "outcome": "success",
  "rates": [
    {
      "period": "Summer",
      "hotel": "FloatingPointResort",
      "room": "SingletonRoom",
      "rate": 249.99,
      "status": "success",
      "valid_until": "2026-05-10T12:34:56.000Z"
    }
  ]
}
```

**`PARTIAL_SUCCESS` some rates unavailable (HTTP 200)**
```json
{
  "outcome": "partial_success",
  "message": "Some rates are currently unavailable",
  "rates": [
    {
      "period": "Summer",
      "hotel": "FloatingPointResort",
      "room": "SingletonRoom",
      "rate": 249.99,
      "status": "success",
      "valid_until": "2026-05-10T12:34:56.000Z"
    },
    {
      "period": "Winter",
      "hotel": "GitawayHotel",
      "room": "BooleanTwin",
      "status": "error",
      "error": "Rate not available"
    }
  ]
}
```

**`FAILURE` all rates unavailable, upstream responded with missing or invalid data after retries exhausted (HTTP 503)**
```json
{
  "outcome": "failure",
  "message": "Rates are temporarily unavailable"
}
```

**`ERROR` upstream threw an exception or returned an error status after retries exhausted (HTTP 502)**
```json
{
  "outcome": "error",
  "message": "Pricing system is temporarily unavailable"
}
```

**`ERROR` invalid request parameters (HTTP 400)**
```json
{
  "outcome": "error",
  "message": "Invalid parameters were provided",
  "errors": [
    "Period must be one of: Summer, Autumn, Winter, Spring"
  ]
}
```

## How to Run
```bash
# --- 1. Build and run the Main Application ---
# Build and run the docker compose
docker compose up -d --build

# --- 2. Test the Endpoints ---
# Single endpoint
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'

# Bulk endpoint
curl -X POST http://localhost:3000/api/v1/pricing/bulk \
  -H "Content-Type: application/json" \
  -d '{ 
        "pricing": [
          {"period": "Summer", "hotel": "FloatingPointResort", "room": "SingletonRoom"}, 
          {"period": "Winter", "hotel": "GitawayHotel", "room": "BooleanTwin"}
        ]
      }' 

# --- 3. Run the Tests ---
# Full suite
docker compose exec interview-dev ./bin/rails test

# Specific file
docker compose exec interview-dev ./bin/rails test test/services/pricing_service_test.rb
```

Thank you for reviewing my submission! 