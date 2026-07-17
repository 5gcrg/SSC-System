# Test Deployment (Railway) — Changes & Optimizations vs `main`

This documents everything the `test/railway-deployment` branches changed relative to `main`,
plus the Railway infrastructure configuration that lives outside git. It is the checklist for
applying the same changes to the production deployment (the `prod` branches).

Deployment date range: July 2026 · Railway project: `generous-patience` (environment `production`).

---

## 1. Backend — `ssc-booking-backend`

| Commit | Change |
|---|---|
| `6dccc8b` | Make backend settings dynamic with env vars for Railway (DB, JWT, CORS, fileserver URL) |
| `48e590a` | Make auth cookie `secure` and `sameSite` configurable via env vars (cross-domain cookies) |
| `685722e` | **N+1 fix:** `getSubmissionsForAdminReview` uses bulk summary mapping (`findAllById` / `findBySubmissionIdIn` + in-memory maps) |
| `74e8d14` | **N+1 elimination across the service layer** (details below) |

### `74e8d14` details — query-count reductions

Extends the bulk-mapping pattern from `685722e` to every remaining per-row lookup hotspot:

- `SubmissionService.toResponse` / `toDocumentResponse` — submission detail page went from
  **~40–50 queries → ~8**. Prefetches assignments (`findByDocumentIdIn`), reviews
  (`findByAssignmentIdIn`), moderator names, and latest document versions once per submission.
  Also removes a duplicated `findByAssignmentId` call in the rejection-remarks stream and adds a
  null-decision guard (escalation-only reviews have `decision == null` and previously NPE'd).
- `ReviewService.getAssignedDocuments` — ~5 queries per assignment row → **~7 total**.
- `ReviewService.getReviewHistory` — ~6 queries per row × page size → **~7 per page**.
- `ReviewService.getEscalatedSubmissions` (admin dashboard) — ~6 per escalation → **~7 total**.
- `ReviewService.getSubmissionReviews` — nested N+1 → **4 queries**.
- `AuditLogService` — one user lookup per audit row → **one per page/list**.
- `AnalyticsService.getMonthlyTurnaround` — `findAll()` + `findById` per review → bulk fetch.
- `AnalyticsService.getModeratorPerformance` — 2 queries per moderator → **3 total**.

New derived repository finders: `ModeratorAssignmentRepository.findByDocumentIdIn`,
`ModeratorAssignmentRepository.findByModeratorIdInAndIsActive`,
`DocumentVersionRepository.findByDocumentIdIn`.

This resolved the ~8k-query spikes visible in the Railway MySQL metrics.

## 2. Fileserver — `ssc-booking-fileserver`

| Commit | Change |
|---|---|
| `0bef35f` | Make fileserver settings dynamic with env vars for Railway (MinIO, JWT, CORS) |
| `5fde4de` | Don't crash at startup when MinIO is unreachable (bucket init logs a warning instead) |
| `26c8f22` | Disable `X-Frame-Options` so the frontend can embed PDFs in an `<iframe>` |
| `932b157` | Local filesystem storage fallback when `MINIO_URL` contains `dummy` + public `GET /api/v1/files/download` endpoint |
| `767ae59` | Force HTTPS scheme on generated URLs for `.up.railway.app` domains (mixed-content fix) |
| `eb5bd5d` | **Security:** path-traversal guard on the public download endpoint — bucket whitelist + base-dir `startsWith` check centralized in `FileStorageService.resolveLocalPath` / `loadAsResource`; missing file returns 404 instead of blanket 500 |

## 3. Frontend — `ssc-booking-frontend`

| Commit | Change |
|---|---|
| `f3b80e9` | Rebuild trigger (no code change) |
| `86a7a27` | Rename `Button.tsx` → `button.tsx` for case-sensitive Linux builds |
| `7496261` | Proxy API requests via Next.js rewrites (first pass at cross-domain cookie fix) |
| `a2f9083` | Custom BFF proxy router under `app/api` — cookies stay same-origin (supersedes rewrites approach) |
| `9a26379` | Resolve leftover conflict markers in `lib/api/client.ts` |
| `92247e7` | Stream upload bodies through the BFF proxy (fixes 502 Bad Gateway on file uploads) |
| `1870536` | Moderator PDF viewer actions layout refactor |

## 4. Railway infrastructure (NOT in git — must be replicated manually for prod)

### MinIO object storage — service `Bucket`

The root cause of the PDF-viewer 404s: with no MinIO, the fileserver's local-disk fallback wrote
to the container's ephemeral filesystem, which Railway wipes on every redeploy. Fixed by deploying
real MinIO:

- Image: **official `minio/minio:latest`** — Railway's `minio` template shipped a broken image
  reference (`railwayapp-templates/minio`, fails at container creation) so the source was switched.
- Start command: `minio server /data --console-address :9001`
- **Volume mounted at `/data`** (this is what makes uploads survive redeploys)
- Public domain targeting **port 9000** (S3 API; browsers fetch presigned URLs from it)
- The template's `MINIO_BROWSER_REDIRECT_URL=https://` variable is malformed and crash-loops
  MinIO (`scheme appears with empty host`) — **delete it**.
- Template-generated `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` kept as credentials.

### Fileserver service variables (reference syntax keeps credentials in sync)

```
MINIO_URL        = ${{Bucket.MINIO_PRIVATE_ENDPOINT}}        → http://bucket.railway.internal:9000
MINIO_PUBLIC_URL = https://${{Bucket.MINIO_PUBLIC_HOST}}     → presigned-URL host browsers load
MINIO_ACCESS_KEY = ${{Bucket.MINIO_ROOT_USER}}
MINIO_SECRET_KEY = ${{Bucket.MINIO_ROOT_PASSWORD}}
```

Buckets `ssc-documents` / `ssc-templates` are auto-created at fileserver startup by
`MinioBucketInitializer` — deploy MinIO first, then (re)start the fileserver and confirm the
`Created MinIO bucket: …` log lines.

### Backend service variables

```
MANAGEMENT_HEALTH_MAIL_ENABLED = false
```

The Spring mail health indicator hangs ~134s trying to reach SMTP (unroutable from Railway;
email is disabled anyway) and turned `/actuator/health` into a 503. With this flag health
returns 200 in <1s.

Pre-existing per-service env vars a prod environment needs equivalents of: `DB_URL` /
`DB_USERNAME` / `DB_PASSWORD`, `JWT_SECRET`, `ALLOWED_ORIGINS`, `FILESERVER_URL`,
`FRONTEND_URL`, cookie secure/sameSite flags, `NEXT_PUBLIC_API_URL`.

## 5. Applying to prod — what to port and what to skip

**Cherry-pick to prod branches (code):**
- Backend: `6dccc8b`, `48e590a`, `685722e`, `74e8d14`
- Fileserver: `0bef35f`, `5fde4de`, `26c8f22`, `767ae59`, `eb5bd5d` (and `932b157` only if the
  local-disk fallback is wanted as a dev convenience — prod should run real MinIO)
- Frontend: `86a7a27`, `a2f9083`, `92247e7`, `1870536` (and `7496261` only as the base the BFF
  proxy builds on — apply in commit order)

**Replicate manually (infra):** everything in section 4.

**Skip (test-only noise):** `f3b80e9` (rebuild trigger), `9a26379` (fixes a conflict that only
ever existed on the test branch).

**Data caveat:** any file uploaded while storage was ephemeral is unrecoverable; the DB rows
referencing those objectKeys will 404 until re-uploaded or deleted.
