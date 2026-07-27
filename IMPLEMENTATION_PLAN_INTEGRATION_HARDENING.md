# Implementation Plan: Read-Only Masterlist Integration & Scoped Project-File API

## Context

External services (e.g. Next.js apps from other teams) consume the masterlist via `X-API-Key`. Two problems:

1. The integration surface currently allows **writes** (`POST /api/v1/integration/masterlist` and `/batch`) — external callers should never mutate the masterlist. It must become strictly read-only.
2. External services also need **file storage**, but the fileserver today has no API-key mechanism and no path authorization — any authenticated principal can presign any object in a bucket. External callers must get file access **strictly scoped to their own project folder** (`projects/<their-folder>/…`); anything outside → 403.

Decisions made with the user:
- External services call the **fileserver directly** (new `X-API-Key` filter there, mirroring the backend's `MasterlistApiKeyFilter`).
- **Per-service API keys** replace the single `MASTERLIST_API_KEY` (config registry: name, key, capabilities). One key per external service, revocable individually.
- Approved file ops: **upload/overwrite, presigned download, list, delete** — all within their folder only.
- New dedicated **`ssc-projects` bucket** (hard separation from `ssc-documents`/`ssc-templates`).

Two git submodules are touched: `ssc-booking-backend` (`com.cjc.ssc.booking`) and `ssc-booking-fileserver` (`com.ssc.booking`, Spring Boot 3.3.5, Java 21, io.minio 8.5.9).

Verified facts that shape the design:
- `upsertFromIntegration` (MasterlistService.java:60-77) has **no callers besides the two integration POSTs** — safe to delete. `UpsertMasterlistRequest` stays (admin `MasterlistController` create/update uses it).
- Backend filter order (`SecurityConfig.java:86-88`): `rateLimitFilter → jwtAuthFilter → masterlistApiKeyFilter`. Rate limiting runs **before** key resolution — per-client-name buckets are impossible there; key by hashed header instead.
- Backend CORS already allows `X-API-Key`. Fileserver needs **no** CORS change (server-to-server).
- Both services bind config prefix `app` and are launched from one shell by `scripts/start-all.ps1` — env var names must be **service-distinct** (no Spring indexed `APP_INTEGRATION_CLIENTS_0_*` binding; it would collide).
- Fileserver sanitizers `sanitizeFilename` / `sanitizeObjectSegment` live in `FileStorageService.java:187-220` — reuse via extraction.
- Fileserver presigned-URL pattern: `FileStorageService.getPresignedDownloadUrl` (lines 83-105) builds a public-URL MinioClient pinned to `us-east-1`, expiry `minio.presigned-url-expiry` — reuse.

## Config format (both services)

Fixed client "slots" in `application.yml` fed by service-distinct env vars; registry ignores slots with blank `api-key`. No custom parsing.

**Backend `application.yml`** (replaces `masterlist-api-key: ${MASTERLIST_API_KEY:}` at ~line 76):

```yaml
app:
  integration:
    clients:
      # Slot 1 falls back to legacy MASTERLIST_API_KEY for zero-downtime migration;
      # remove the fallback once env files are updated.
      - name: ${MASTERLIST_CLIENT_1_NAME:registrar}
        api-key: ${MASTERLIST_CLIENT_1_KEY:${MASTERLIST_API_KEY:}}
        allow-sensitive: ${MASTERLIST_CLIENT_1_ALLOW_SENSITIVE:false}
      - name: ${MASTERLIST_CLIENT_2_NAME:}
        api-key: ${MASTERLIST_CLIENT_2_KEY:}
        allow-sensitive: ${MASTERLIST_CLIENT_2_ALLOW_SENSITIVE:false}
      - name: ${MASTERLIST_CLIENT_3_NAME:}
        api-key: ${MASTERLIST_CLIENT_3_KEY:}
        allow-sensitive: ${MASTERLIST_CLIENT_3_ALLOW_SENSITIVE:false}
```

**Fileserver `application.yml`:**

```yaml
app:
  integration:
    clients:
      - name: ${PROJECT_CLIENT_1_NAME:}
        api-key: ${PROJECT_CLIENT_1_KEY:}
        project-folder: ${PROJECT_CLIENT_1_FOLDER:}
      - name: ${PROJECT_CLIENT_2_NAME:}
        api-key: ${PROJECT_CLIENT_2_KEY:}
        project-folder: ${PROJECT_CLIENT_2_FOLDER:}
      - name: ${PROJECT_CLIENT_3_NAME:}
        api-key: ${PROJECT_CLIENT_3_KEY:}
        project-folder: ${PROJECT_CLIENT_3_FOLDER:}
    rate-limit:
      enabled: true
      capacity: ${INTEGRATION_RATE_LIMIT_CAPACITY:60}
      refill-tokens: ${INTEGRATION_RATE_LIMIT_REFILL_TOKENS:60}
      refill-period-seconds: ${INTEGRATION_RATE_LIMIT_REFILL_PERIOD_SECONDS:60}
```

**Root `.env.example` additions:**

```
# -- Backend masterlist integration clients (read-only) --
MASTERLIST_CLIENT_1_NAME=registrar
MASTERLIST_CLIENT_1_KEY=<move existing MASTERLIST_API_KEY value here>
MASTERLIST_CLIENT_1_ALLOW_SENSITIVE=false

# -- Fileserver project-storage clients --
PROJECT_CLIENT_1_NAME=acme
PROJECT_CLIENT_1_KEY=<generate: openssl rand -hex 32>
PROJECT_CLIENT_1_FOLDER=acme-app
```

Startup validation (both registries): drop blank-key slots; log loaded client **names only** (never keys); fileserver additionally requires non-blank `project-folder` passing `sanitizeObjectSegment` (fail fast) and rejects duplicate keys/names.

## Phase 1 — Backend: masterlist strictly read-only

Files under `ssc-booking-backend\src\main\java\com\cjc\ssc\booking\`:
1. `controller\MasterlistIntegrationController.java` — delete `upsert` (39-42) and `upsertBatch` (44-48); drop unused imports (`UpsertMasterlistRequest`, `Valid`); update javadoc.
2. `service\MasterlistService.java` — delete `upsertFromIntegration` (60-77); tidy imports.
3. `security\MasterlistApiKeyFilter.java` — defense in depth: reject non-GET on the integration path with **405** "Masterlist integration is read-only." via the existing JSON `reject(...)` helper (extend to accept the error label).

Do **not** delete `UpsertMasterlistRequest` (admin CRUD uses it).

## Phase 2 — Backend: per-client key registry

1. `config\AppProperties.java` — replace `Integration.masterlistApiKey` (50-54):

```java
@Data
public static class Integration {
    private List<Client> clients = new ArrayList<>();
    @Data
    public static class Client {
        private String name;
        private String apiKey;
        private boolean allowSensitive = false; // gates includeSensitive=true
    }
}
```

2. `security\MasterlistApiKeyFilter.java` — keep name, header, `shouldNotFilter`, constant-time `MessageDigest.isEqual`:
   - No configured clients → 401 "Integration API key is not configured." Missing header → 401. Iterate all clients with constant-time compare; no match → 403.
   - On match: `request.setAttribute("integration.client", client.getName())`.
   - **Sensitive gate in the filter**: if `includeSensitive` param parses true and client lacks `allowSensitive` → 403 "This client is not permitted to read sensitive fields." (Controller untouched; authorization stays in one place.)
   - Access logging (replaces the removed write-side audit): after `doFilter`, `log.info("masterlist-integration access client={} method={} path={} includeSensitive={} status={}")`. slf4j only — DB audit rows per read poll would be noisy. Never log the key.
3. `application.yml` — clients block above; `application-prod.yml` — comment pointing at `MASTERLIST_CLIENT_n_*` vars.

No SecurityConfig matcher changes needed (`/api/v1/integration/masterlist/**` permitAll already matches the bare path under PathPattern).

## Phase 3 — Backend: rate-limit the integration path

Extend `security\RateLimitFilter.java` (in-memory, single-instance by design):
- Add `INTEGRATION_PREFIX = "/api/v1/integration/"` to its path routing; new `integrationBuckets` map; new `Bucket integration` in `AppProperties.RateLimit`.
- Bucket key: `sha256hex(X-API-Key header)` when present, else client IP (filter runs before key resolution; hashing avoids storing raw keys and throttles brute-force attempts). **Do not reorder the filter chain.**
- yml under `app.rate-limit`:

```yaml
    integration:
      capacity: ${RATE_LIMIT_INTEGRATION_CAPACITY:30}
      refill-tokens: ${RATE_LIMIT_INTEGRATION_REFILL_TOKENS:30}
      refill-period-seconds: ${RATE_LIMIT_INTEGRATION_REFILL_PERIOD_SECONDS:60}
```

## Phase 4 — Fileserver: config groundwork

Files under `ssc-booking-fileserver\src\main\java\com\ssc\booking\`:
1. `config\AppProperties.java` — add nested `Integration` (getter/setter style matching the file): `List<Client> clients` (`name`, `apiKey`, `projectFolder`) + nested `RateLimit` (`enabled`, `capacity`, `refillTokens`, `refillPeriodSeconds`).
2. `config\MinioProperties.java` — add `Buckets.projects`; `int maxProjectFileSizeMb` (default 25); `List<String> blockedExtensions`.
3. `config\MinioBucketInitializer.java` — auto-create the projects bucket.
4. `application.yml`:

```yaml
minio:
  buckets:
    projects: ssc-projects   # alongside documents/templates
  max-project-file-size-mb: ${MAX_PROJECT_FILE_SIZE_MB:25}
  blocked-extensions: exe,dll,msi,bat,cmd,com,scr,pif,vbs,ps1,sh
```

Content-type policy: extension **denylist** (configurable), not an allowlist — external projects need arbitrary asset types; files are only served via presigned MinIO URLs (never from the app origin), so stored-XSS-into-app-domain doesn't apply. Store `file.getContentType()` (fallback `application/octet-stream`); never trust it for validation.

Size cap: separate 25MB project cap; existing 10MB document cap untouched. Servlet ceiling is `spring.servlet.multipart.max-file-size: 50MB` — keep project cap below it. Cosmetic: `GlobalExceptionHandler.handleMaxUploadSize` hardcodes "10MB" — make generic.

## Phase 5 — Fileserver: path sanitization + ProjectFileStorageService

Extract `sanitizeFilename`/`sanitizeObjectSegment` from `FileStorageService.java` into new package-private `service\ObjectKeySanitizer.java` (FileStorageService delegates — zero behavior change); add `sanitizeRelativePath` there.

### sanitizeRelativePath (reject-first; violation → `FilePathViolationException` → 403)

Reject if: null/blank or > 512 chars; contains `\`; starts with `/`, contains `//`, or ends with `/`; contains control chars or `%` (avoids double-decoding ambiguity — policy choice). Then split on `/` (max 20 segments); each segment: reject blank/`.`/`..` **before** any character replacement; last segment through `sanitizeFilename`, intermediates through `sanitizeObjectSegment`; re-check post-sanitization; rejoin.

**Key construction — caller never supplies the folder:** `objectKey = "projects/" + client.projectFolder + "/" + sanitizedRelativePath`. `projectFolder` comes from the registry entry resolved by the key filter (validated at startup), never from the request. Final assertion: key starts with `projects/<folder>/`, no `..` segments, length ≤ 1024. Same treatment for `path`/`prefix` on download/list/delete; list responses strip the prefix so callers only ever see folder-relative keys.

New `service\ProjectFileStorageService.java` (methods take the resolved `Client`):
- `upload(client, relativePath, file)` — size cap, extension denylist, `statObject` for `overwritten` flag, `putObject` **streaming** (`.stream(inputStream, size, -1)` — same pattern as FileStorageService:150-163; never buffer to memory). Returns relative key.
- `presignedDownloadUrl(client, relativePath)` — `statObject` first (404 `FILE_NOT_FOUND` if missing), then reuse the extracted presigned-URL logic (public-URL client, `us-east-1`, `minio.presigned-url-expiry`).
- `list(client, subPrefix, maxKeys, startAfter)` — `ListObjectsArgs` with full prefix, `recursive(true)`; default 100, cap 1000; fetch maxKeys+1 to compute `truncated`; return relative keys + size/lastModified/etag + `nextStartAfter`.
- `delete(client, relativePath)` — `removeObject`; **idempotent 204** even for missing keys (avoids stat race + round-trip; documented).

New `exception\FilePathViolationException` → `GlobalExceptionHandler` maps to 403 `{"code":"PATH_VIOLATION","message":"Invalid file path.","status":403}`. Size/extension/missing-file failures remain `FileValidationException` → 400.

## Phase 6 — Fileserver: IntegrationApiKeyFilter + SecurityConfig

New `security\IntegrationApiKeyFilter.java` (mirrors backend filter):
- `OncePerRequestFilter`; `shouldNotFilter` unless path starts with `/api/v1/integration/files` (cover bare + `/`-suffixed, same pattern as backend).
- Constant-time registry lookup; 401 no-clients/missing-header, 403 invalid key. Errors use the fileserver `ErrorResponse` shape `{code, message, status, timestamp}` (`API_KEY_MISSING`, `API_KEY_INVALID`, `NOT_CONFIGURED`).
- On match: `request.setAttribute("integration.client", client)` (whole object — controller needs `projectFolder`).
- **Rate limiting inside this filter**, after key resolution, keyed by client name (mini token bucket copied from backend `RateLimitFilter`: ConcurrentHashMap + refill + 429 with `Retry-After`). Avoids all filter-ordering questions. Config `app.integration.rate-limit.*`.
- Access log in `finally`: `log.info("project-files access client={} method={} path={} status={}")`. Never log keys.

`config\SecurityConfig.java`: add `.requestMatchers("/api/v1/integration/files/**").permitAll()` before `anyRequest().authenticated()`; register filter as `@Bean` + `.addFilterBefore(..., UsernamePasswordAuthenticationFilter.class)`. Verified: existing `JwtAuthenticationFilter` continues the chain when no token — no interference. Filter-bean double-registration matches existing backend pattern; `OncePerRequestFilter` dedupes — harmless. **No CORS change** (server-to-server by design; note in README).

## Phase 7 — Fileserver: integration controller + DTOs

New `controller\IntegrationFileController.java`, `@RequestMapping("/api/v1/integration/files")`, no `@PreAuthorize` (filter is the gate); reads client from request attribute. Relative paths travel as **query/form params, never path variables** (slashes get mangled).

Common errors: 401 `API_KEY_MISSING`/`NOT_CONFIGURED`, 403 `API_KEY_INVALID`/`PATH_VIOLATION`, 429 rate-limited.

**Upload/overwrite**
```
POST /api/v1/integration/files      (multipart/form-data)
  file: <binary>              path: builds/v1.2/app.zip
201 { "key": "builds/v1.2/app.zip", "size": 1048576, "contentType": "application/zip",
      "overwritten": false, "uploadedAt": "..." }
400 FILE_VALIDATION_ERROR | 403 PATH_VIOLATION
```
New record `dto\ProjectFileUploadResponse`.

**Download (presigned — bytes never proxy through the app)**
```
GET /api/v1/integration/files/url?path=builds/v1.2/app.zip
200 { "url": "http://<minio.public-url>/ssc-projects/projects/acme-app/...?X-Amz-...",
      "expiresAt": "...", "expiresInSeconds": 3600 }        (reuse dto\PresignedUrlResponse)
404 FILE_NOT_FOUND | 403 PATH_VIOLATION
```

**List**
```
GET /api/v1/integration/files?prefix=builds/&maxKeys=100&startAfter=<relative-key>
200 { "files": [ { "key": "builds/v1.2/app.zip", "size": ..., "lastModified": "...", "etag": "..." } ],
      "truncated": true, "nextStartAfter": "builds/v1.2/app.zip" }
```
Keys always relative (prefix stripped). New records `dto\ProjectFileInfo`, `dto\ProjectFileListResponse`.

**Delete**
```
DELETE /api/v1/integration/files?path=builds/v1.2/app.zip
204 always (idempotent, documented) | 403 PATH_VIOLATION
```

## Phase 8 — Docs, env, submodules

1. Root `.env.example` — add both client blocks (it does not currently contain `MASTERLIST_API_KEY`; nothing to remove).
2. Both services' `application.yml`/`application-prod.yml` per phases above.
3. READMEs: root; backend (read-only integration, per-client keys, migration note); fileserver (endpoint table, isolation model, `MINIO_PUBLIC_URL` reachability note, no-CORS-by-design note). Check `ssc-booking-backend\docs\` for an existing integration guide to update.
4. Submodules: commit inside each submodule on its branch, then one superproject commit bumping both gitlinks + root doc changes. Ignore `target\` yml copies (build artifacts).

## Phase 9 — Verification

Builds: `mvn clean package -DskipTests` in each submodule.

**Backend masterlist** (`http://localhost:8081`, `MKEY` = client key):
- GET with key → 200, no sensitive fields; no header → 401; wrong key → 403.
- POST with valid key → **405** (read-only guard).
- `?includeSensitive=true` → 403 when `allow-sensitive=false`; 200 with fields when true.
- Burst over capacity → 429 + `Retry-After`.
- Regression: admin masterlist CRUD via JWT still works.

**Fileserver** (`http://localhost:8080`, KEY_A/KEY_B → folders `acme-app`/`beta-app`):
- Upload KEY_A `path=builds/v1/app.zip` → 201; re-upload → `overwritten:true`; MinIO console shows `ssc-projects/projects/acme-app/builds/v1/app.zip`.
- Traversal negatives all → 403: `../other/app.zip`, `/etc/passwd`, `a\..\b`, `a//b`, `..`, `builds/%2e%2e/x`, `prefix=../`.
- Wrong key → 403; no key → 401.
- **Cross-folder isolation**: KEY_B list must not show A's files; KEY_B url for A's path → 404.
- Blocked extension (`run.exe`) → 400; oversize → 400.
- Presigned URL fetch from the **calling machine** (not just localhost) → bytes (proves `MINIO_PUBLIC_URL` reachability).
- Pagination: 3 files, `maxKeys=2` → truncated + follow-up returns the third.
- Delete → 204; repeat → 204; url after delete → 404.
- Regression: JWT-gated `/api/v1/files/...` still works; `/actuator/health` 200.
- Startup logs show client names; grep logs for key substrings → none.

## Risks

1. **Existing masterlist consumer**: their POSTs now 405 (intended); key migrates zero-downtime via the `MASTERLIST_API_KEY` fallback. Coordinate the read-only cutover with them.
2. **Filter ordering (backend)**: rate limiter runs before key resolution — hence hashed-key buckets; don't reorder the chain.
3. **Presigned URL reachability**: URLs embed `minio.public-url`; external callers need that host reachable from *their* network, and the signature binds to the exact host (mismatch → MinIO signature error).
4. **Shared-env var naming is load-bearing**: `MASTERLIST_CLIENT_*` vs `PROJECT_CLIENT_*` must stay distinct — both services bind prefix `app` from one shell.
5. **Servlet 50MB multipart ceiling** caps uploads before validators run; raising the project cap beyond it requires touching that too.
6. In-memory rate limiting is per-instance by design — fine for single-instance deployment.
7. `ssc-projects` bucket auto-create soft-fails with a warning (matches existing buckets); first upload would then 500.
