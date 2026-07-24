# Security & Performance Work — SSC Booking System

## Security Fixes

### Backend (`ssc-booking-backend`)
- **Broken access control**: `GET /api/v1/students` and `/students/{id}` only required
  `isAuthenticated()`, letting any Moderator or Student account read every student's PII
  (email, contact number, department, org, year level). Restricted to admin roles.
  (`f3742d6`)
- **Exposed dev backdoor**: `DevController` minted a login JWT for *any* user with no auth,
  gated only by `@Profile("!prod")` — but the documented production setup never activates a
  `prod` Spring profile, so it was live in production. Replaced with an explicit
  `@ConditionalOnProperty(app.dev-endpoints.enabled)`, default `false`. (`92013d1`)
- **Hardcoded secrets**: JWT secret, mail credentials, and MinIO access/secret keys were
  committed in `application.yml`. Externalized to env vars with safe (non-functional) dev
  fallbacks. (`92013d1`, mirrored in fileserver via `5d427d3`)
- **Rate limiting**: added a per-IP token-bucket `RateLimitFilter` scoped to
  `/api/v1/auth/**`, `/api/v1/submissions/**`, `/api/v1/students/**`. (`6b34cc6`)
- **Security headers**: HSTS, `X-Frame-Options`, `X-Content-Type-Options`, and a tightened
  CORS allowed-headers list. (`6b34cc6`)
- **Cookie hardening**: `secure`/`sameSite` cookie flags made configurable via env vars
  instead of hardcoded. (`48e590a`)
- **Machine-to-machine auth**: the external registrar masterlist integration
  (`/api/v1/integration/masterlist/**`) is gated by a constant-time `X-API-Key` comparison
  (`MasterlistApiKeyFilter`), independent of the JWT/session model used elsewhere.
- **Error handling gap**: unmapped paths (including the now-disabled dev endpoint) fell
  through to a catch-all and returned `500` instead of `404`, leaking stack-trace-adjacent
  behavior. Added a proper `NoResourceFoundException` handler. (`92013d1`)

### Fileserver (`ssc-booking-fileserver`)
- Same credential-externalization pass as the backend: MinIO and JWT secrets moved out of
  `application.yml` into env vars. (`5d427d3`)
- Hardened against MinIO being unreachable at startup (prevents crash-loop). (`5fde4de`)

### Frontend (`ssc-booking-frontend`)
- **Security headers**: `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`,
  `Permissions-Policy`, HSTS added via `next.config.ts`. (`3f39cd2`)
- **Info leak**: raw backend error messages were surfaced directly to the UI; now sanitized
  before display. (`3f39cd2`)
- **Cross-domain cookies**: replaced direct cross-origin API calls with a custom BFF proxy
  router under `app/api` so auth cookies aren't exposed cross-domain. (`a2f9083`, `7496261`)

## Performance Optimizations

### Backend
- **N+1 query elimination** — the big one, done in two passes:
  - `getSubmissionsForAdminReview`: bulk summary mapping instead of per-row lookups. (`685722e`)
  - Extended the same pattern to `ReviewService` (assigned documents, review history,
    escalations, submission reviews), `SubmissionService.toResponse`/`toDocumentResponse`
    (~40–50 queries per submission detail view down to ~8), `AuditLogService`, and
    `AnalyticsService`. Added batch finders (`findByDocumentIdIn`,
    `findByModeratorIdInAndIsActive`) to support it. (`74e8d14`)
- **Database indexes**: `V42__add_performance_indexes.sql` migration. (`3f159a8`)
- **Caching**: `@Cacheable`/`@CacheEvict` added to `DepartmentService`, `SdpCategoryService`,
  `SystemSettingsService`, and later `OrganizationService`. (`3f159a8`, `6b34cc6`)
- **Connection pool tuning** (HikariCP settings in `application.yml`). (`3f159a8`)

### Frontend
- Memoized filter/group computations on the moderator assigned-documents list to avoid
  redundant re-renders. (`3f39cd2`)
- Search input debouncing on student/list views. (`3752e25`)
- Streamed upload bodies through the BFF proxy instead of buffering, fixing 502s on large
  file uploads. (`92247e7`)
