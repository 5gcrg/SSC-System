# Verification Report — Integration Hardening

Verification of the changes from `IMPLEMENTATION_PLAN_INTEGRATION_HARDENING.md`
(read-only masterlist integration + per-client API keys + departments/organizations
integration endpoints on the backend; scoped project-file API on the fileserver).

- **Commits under test:** backend `2b2299d`, fileserver `32e97ca`, superproject `42ab6f2`
  (branch `test/railway-deployment` in all three repos).
- **Result: 45/45 checks passed in 3 consecutive full passes** (135/135 total),
  identical outcomes every pass.
- **Date:** 2026-07-26, run locally on Windows against live services.

---

## How the tests were run

Each pass started **freshly restarted services** (so startup behavior — client-registry
validation, names-only logging, `ssc-projects` bucket auto-creation — was itself exercised
three times), ran the full 45-check matrix, and cleaned up its test objects.

Test script: [`scripts/test-integration-matrix.sh`](scripts/test-integration-matrix.sh)
(run from Git Bash). Reproduce by starting MinIO and both services with the env vars below,
then running the script — it prints one PASS/FAIL line per check and a summary, and cleans
up its own test objects.

**Environment (throwaway test keys):**

```
MinIO:       .tools\minio.exe server .tools\minio-data  (sscadmin / sscpassword123)
Backend:     MASTERLIST_API_KEY=legacy-key-0000111122223333          <- slot-1 legacy fallback, allow-sensitive=false
             MASTERLIST_CLIENT_2_NAME=sensitive-app
             MASTERLIST_CLIENT_2_KEY=test-key-s-aaaabbbbccccdddd
             MASTERLIST_CLIENT_2_ALLOW_SENSITIVE=true
Fileserver:  PROJECT_CLIENT_1 = acme / test-key-a-0123456789abcdef / folder acme-app
             PROJECT_CLIENT_2 = beta / test-key-b-fedcba9876543210 / folder beta-app
```

Note the backend slot-1 client authenticates via the **legacy `MASTERLIST_API_KEY`
fallback** — this doubles as the zero-downtime key-migration test.

---

## Backend checks (http://localhost:8081) — 19/19 × 3 passes

### Authentication & read-only guard

| # | Check | Request | Expected | Got (all 3 passes) |
|---|-------|---------|----------|--------------------|
| 1 | List with valid key | `GET /api/v1/integration/masterlist` + legacy key | 200 | 200 |
| 2 | By-ID with valid key | `GET /api/v1/integration/masterlist/1234-5678-9` | 200 | 200 |
| 3 | Missing key | `GET /api/v1/integration/masterlist` (no header) | 401 | 401 |
| 4 | Wrong key | header `X-API-Key: wrong` | 403 | 403 |
| 5 | Write blocked | `POST /api/v1/integration/masterlist` + **valid** key | 405 | 405 |
| 6 | Batch write blocked | `POST /api/v1/integration/masterlist/batch` + valid key | 405 | 405 |
| 7 | PUT blocked | `PUT /api/v1/integration/masterlist` + valid key | 405 | 405 |

### Per-client sensitive-field gate

| # | Check | Request | Expected | Got |
|---|-------|---------|----------|-----|
| 8 | Denied without capability | `?includeSensitive=true` + legacy key (`allow-sensitive=false`) | 403 | 403 |
| 9 | Allowed with capability | `?includeSensitive=true` + sensitive-app key | 200 | 200 |

(Additionally spot-checked earlier: the sensitive response body is larger — sensitive
values populated only when permitted; field gating itself is pre-existing DTO behavior.)

### Departments / Organizations integration endpoints (new)

| # | Check | Request | Expected | Got |
|---|-------|---------|----------|-----|
| 10 | Departments with key | `GET /api/v1/integration/departments` | 200 | 200 |
| 11 | Departments without key | same, no header | 401 | 401 |
| 12 | Departments write blocked | `POST /api/v1/integration/departments` + valid key | 405 | 405 |
| 13 | Organizations with filter | `GET /api/v1/integration/organizations?active=true` | 200 | 200 |
| 14 | Department by ID | `GET /api/v1/integration/departments/{id}` (id from list) | 200 | 200 |
| 15 | Organization by ID | `GET /api/v1/integration/organizations/{id}` (id from list) | 200 | 200 |

### Regressions (public endpoints untouched)

| # | Check | Request | Expected | Got |
|---|-------|---------|----------|-----|
| 16 | Public departments | `GET /api/v1/departments` (no key) | 200 | 200 |
| 17 | Public organizations | `GET /api/v1/organizations` (no key) | 200 | 200 |

### Rate limiting (capacity 30, refill 30/60s, keyed by hashed API key)

| # | Check | Method | Expected | Got |
|---|-------|--------|----------|-----|
| 18 | Burst of 40 requests | 40 rapid GETs with one key | mixed 200/429; successes ≤ 30; every request answered | pass 1: mixed ok · pass 2: ok · pass 3: ok |
| 19 | `Retry-After` on 429 | inspect headers of a throttled response | header present, ≥ 1s | `Retry-After: 2` observed |

---

## Fileserver checks (http://localhost:8080) — 26/26 × 3 passes

### Upload & auth

| # | Check | Request | Expected | Got |
|---|-------|---------|----------|-----|
| 20 | First upload | `POST /api/v1/integration/files` (`file`, `path=builds/v1/app.zip`) key A | 201, `"overwritten":false` | ✔ |
| 21 | Overwrite | same request again | 201, `"overwritten":true` | ✔ |
| 22 | Missing key | `GET /api/v1/integration/files` (no header) | 401 `API_KEY_MISSING` | 401 |
| 23 | Wrong key | header `X-API-Key: nope` | 403 `API_KEY_INVALID` | 403 |

### Path-traversal rejection (all → 403 `PATH_VIOLATION`)

| # | Attack path | Where | Got |
|---|-------------|-------|-----|
| 24 | `../other/app.zip` | upload `path` | 403 |
| 25 | `/etc/passwd` | upload `path` | 403 * |
| 26 | `a\..\b` | upload `path` | 403 |
| 27 | `a//b` | upload `path` | 403 |
| 28 | `..` | upload `path` | 403 |
| 29 | `builds/%2e%2e/x` | upload `path` | 403 |
| 30 | `../` | list `prefix` | 403 |
| 31 | `../x` | url `path` | 403 |

\* An initial run showed a false 201 for `/etc/passwd`: Git Bash (MSYS) silently rewrote
the argument to `C:/Program Files/Git/etc/passwd` before curl sent it, which the server
correctly stored as a harmless relative key inside the client's own folder. Retested with
`MSYS2_ARG_CONV_EXCL="*"` so the literal string reached the server → 403 in all 3 passes.
The stray object was deleted.

### Upload validation

| # | Check | Request | Expected | Got |
|---|-------|---------|----------|-----|
| 32 | Blocked extension | upload `path=run.exe` | 400 `FILE_VALIDATION_ERROR` ("….exe are not accepted") | 400 |
| 33 | Oversize | upload 26 MB file (cap 25 MB) | 400 ("exceeds the 25MB limit for project files") | 400 |

### Cross-client isolation

| # | Check | Request | Expected | Got |
|---|-------|---------|----------|-----|
| 34 | B cannot list A's files | `GET /files` with key B while A's files exist | `{"files":[],…}` | ✔ empty |
| 35 | B cannot presign A's file | `GET /files/url?path=builds/v1/app.zip` with key B | 404 `FILE_NOT_FOUND` | 404 |

### Presigned download

| # | Check | Expected | Got |
|---|-------|----------|-----|
| 36 | Fetch presigned URL | exact uploaded bytes returned | `PK-test-content-12345` ✔ |
| 37 | Bucket/key layout | URL contains `/ssc-projects/projects/acme-app/builds/v1/app.zip` | ✔ |

### Pagination (3 files, `maxKeys=2`)

| # | Check | Expected | Got |
|---|-------|----------|-----|
| 38 | Page 1 | 2 files, `"truncated":true`, `nextStartAfter` set | ✔ |
| 39 | Page 2 via `startAfter` | remaining 3rd file, `"truncated":false` | ✔ |

### Delete semantics

| # | Check | Request | Expected | Got |
|---|-------|---------|----------|-----|
| 40 | Delete | `DELETE /files?path=docs/readme.md` | 204 | 204 |
| 41 | Delete again | same request | 204 (idempotent) | 204 |
| 42 | Presign after delete | `GET /files/url?path=docs/readme.md` | 404 | 404 |

### Regressions & health

| # | Check | Expected | Got |
|---|-------|----------|-----|
| 43 | JWT-gated `/api/v1/files/...` without auth | still denied (403) | 403 |
| 44 | `/actuator/health` | 200 | 200 |
| 45 | Backend `/api/v1/ping` | 200 | 200 |

---

## Startup & log hygiene (checked across all runs)

- Registry startup log (every fileserver start): `Loaded 2 integration client(s): [acme, beta]` — **names only**.
- `Created MinIO bucket: ssc-projects` on first start; `already exists` on subsequent starts.
- Grep of **all** service logs (backend + fileserver + MinIO, all passes) for any of the four
  test key strings: **0 matches** — keys are never logged.

## Build verification

`mvn clean package -DskipTests` succeeded in both submodules before the runtime passes
(the tested jars were built from the committed sources).

## Known environment limitation

"Presigned URL fetched from the calling machine's network" was verified from localhost only —
this machine has no second network vantage point. The URL embeds `minio.public-url` and the
signature binds to that exact host, so in any real deployment `MINIO_PUBLIC_URL` must be set
to a host the external caller can reach (documented in the fileserver README).
