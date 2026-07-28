# SSC System - Automated Test Suite: Analysis & Findings Report

Generated: 2026-07-28
Total Runs Analyzed: 14
Scope: All reports in reports/ directory

---

## Run Inventory

| # | Run ID | Type | Iterations | Total Checks | Result |
|---|--------|------|:----------:|:------------:|:------:|
| 1 | 50x-antigravity-run-20260728-120836 | Antigravity (early dev) | ~2 | - | Incomplete |
| 2 | 50x-antigravity-run-20260728-121022 | Antigravity (early dev) | ~2 | - | Incomplete |
| 3 | 50x-antigravity-run-20260728-121242 | Antigravity | 2 | ~25 | 13 failures |
| 4 | 50x-antigravity-run-20260728-121646 | Antigravity | 2 | ~24 | 12 failures |
| 5 | 50x-antigravity-run-20260728-122114 | Antigravity | 2 | ~24 | 10 failures |
| 6 | 50x-antigravity-run-20260728-122439 | Antigravity | 2 | ~24 | 3 failures |
| 7 | 50x-antigravity-run-20260728-122840 | Antigravity | 2 | ~28 | 2 failures |
| 8 | 50x-antigravity-run-20260728-123144 | Antigravity | 2 | ~28 | 3 failures |
| 9 | 50x-antigravity-run-20260728-123513 | Antigravity | 2 | 57 | 100% PASS |
| 10 | 50x-antigravity-run-20260728-123746 | Antigravity full 50x | 50 | 1,450 | 100% PASS |
| 11 | 50x-run-20260728-130906 | v2 suite | 2 | 130 | 100% PASS |
| 12 | 50x-run-20260728-131107 | v2 suite full 50x | 50 | 3,212 | 100% PASS |
| 13 | 50x-run-20260728-135011 | v2 suite | 2 | 130 | 100% PASS |
| 14 | 50x-run-20260728-144659 | v2 suite | 2 | 130 | 100% PASS |

---

## Overall Results (Runs 9-14)

| Metric | Value |
|--------|-------|
| Total verified assertions | 5,052+ |
| Total failures | 0 |
| Overall pass rate | 100% |
| Memory leaks detected | None |

---

## Finding 1 - Test Suite Evolution (Runs 1-10)

Runs 120836 to 123144 were development-era runs where the suite itself was being built:

- Runs 1-2: CSV files empty - suite was not yet writing data.
- Runs 3-8: fail_count dropped progressively: 13 to 12 to 10 to 3 to 2 to 3. These failures reflected unfinished endpoints under development, not production regressions.
- Run 9 (123513): First fully clean run - 0 failures. Suite stabilization point.
- Run 10 (123746): First full 50-iteration run at 100% - mature baseline established.

---

## Finding 2 - Full 50-Iteration Stress Test (Runs 10 and 12)

### Run 10: 50x-antigravity-run-20260728-123746

- Iterations: 50
- Total checks: 1,450
- Failures: 0
- Rebuild cycles: 6

Latency by Iteration Type:
- Standard (non-burst): avg 13.1-18.5 ms, p95 ~100 ms
- Rate-limiter burst: avg 52.5-73.2 ms, p95 166-337 ms

Rebuild Timing:
- Backend avg: 14.50s
- Fileserver avg: 7.15s
- Frontend avg: 38.28s
- Cold start avg: 21.82s

All 6 rebuild cycles produced byte-identical JARs (93,796,170 bytes backend; 47,252,704 bytes fileserver) and identical 513-file Next.js output - fully deterministic builds confirmed.

### Run 12: 50x-run-20260728-131107

- Iterations: 50
- Total checks: 3,212
- Failures: 0
- Checks per iteration: 64 normal / 66 burst

Latency:
- Standard iterations: avg 32-44 ms, p95 50-62 ms
- Burst iterations: avg 43-65 ms, p95 73-175 ms

The v2 suite expanded checks from ~28 to 64-66 per iteration. Higher avg latency reflects broader coverage, not degraded performance.

---

## Finding 3 - Rate Limiter Behavior

Across all burst-phase iterations in both full 50-iteration runs:

- >=27 HTTP 200 out of 40 burst requests (within token bucket)
- >=12 HTTP 429 for over-limit requests
- Retry-After header always present (1-2 second values)
- Suite correctly honored Retry-After before retrying
- Integration bucket refill time: 62 seconds (v2 suite)
- Rate limiter survived all 6 rebuild cycles and reset cleanly

---

## Finding 4 - Short Validation Runs (Runs 11, 13, 14)

| Run | Iter 1 avg | Iter 2 avg | Checks | Result |
|-----|:----------:|:----------:|:------:|--------|
| 130906 | 43.7 ms | 35.3 ms | 130 | 130/130 PASS |
| 135011 | 43.6 ms | 32.5 ms | 130 | 130/130 PASS |
| 144659 | 48.4 ms | 34.1 ms | 130 | 130/130 PASS |

Zero regressions after any code changes. All smoke tests clean.

---

## Finding 5 - Security Vulnerabilities (from Security Audit, Run 10)

### 5.1 X-Forwarded-For Header Trust - HIGH
- File: RateLimitFilter.java:138-144
- Risk: Rotating X-Forwarded-For values creates a fresh rate-limit bucket per request, bypassing all IP-based throttling.
- Fix: Configure server.forward-headers-strategy=native or validate against a trusted proxy IP whitelist.

### 5.2 Rate Limiter Runs Before API-Key Validation - HIGH
- Files: RateLimitFilter.java, SecurityConfig.java
- Risk: Unauthenticated requests with a valid partners API key can exhaust that partners token bucket without valid credentials.
- Fix: Reorder filter chain so IntegrationApiKeyFilter runs before RateLimitFilter.

### 5.3 Trailing-Slash Rate Limit Bypass - MEDIUM
- File: RateLimitFilter.java:32-35
- Risk: /api/v1/submissions (no trailing slash) bypasses the rate limiter entirely.
- Fix: Use AntPathMatcher or Spring PathPattern instead of string prefix matching.

### 5.4 Frontend JWT Existence-Only Guard - MEDIUM
- File: ssc-booking-frontend/middleware.ts
- Risk: Any non-empty string in ssc_auth_token cookie passes the middleware - protected HTML served to users with fake tokens.
- Fix: Add edge JWT signature + expiration validation using jose or Web Crypto API.

### 5.5 In-Memory Rate Limiter State - LOW
- Risk: All token buckets wiped on service restart - limits fully reset.
- Fix: Migrate to Redis-backed Bucket4j for persistent distributed rate limiting.

### 5.6 Fileserver Hardcoded Rate Limit Config - LOW
- File: ssc-booking-fileserver/src/main/resources/application.yml:48
- Risk: app.integration.rate-limit.enabled cannot be toggled via environment variable.
- Fix: Change to ${INTEGRATION_RATE_LIMIT_ENABLED:true}.

---

## Finding 6 - System Stability Under Sustained Load

| Indicator | Status |
|-----------|--------|
| Memory leaks (50-iter runs) | None detected |
| Upward latency trend | None - flat from iter 1 to 50 |
| HikariCP DB pool | Stable under maximum-pool-size 20 |
| MinIO file round-trips | ~150 ms throughout |
| Build reproducibility | 100% deterministic - byte-identical JARs every rebuild |
| Cold start predictability | plus-minus 4s variance (~21.8s average) |
| Dev endpoint revert | /api/v1/dev/users returns 404 confirmed after every run |

---

## Remediation Priority Summary

| Priority | Finding | Status |
|:--------:|---------|:------:|
| HIGH | X-Forwarded-For IP spoofing bypass | Unresolved |
| HIGH | Bucket poisoning via unauthenticated API key | Unresolved |
| MEDIUM | Trailing slash rate limit bypass | Unresolved |
| MEDIUM | Frontend JWT existence-only guard | Unresolved |
| LOW | In-memory rate limiter wiped on restart | Acceptable for local deployment |
| LOW | Fileserver hardcoded rate limit toggle | Easy 1-line fix |

---

Analysis generated from 14 runs in reports/ directory - 2026-07-28
