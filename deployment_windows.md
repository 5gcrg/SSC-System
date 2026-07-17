# Deploying the Test-Branch Services on Windows Server — What Must Change

Companion to [SETUP.md](SETUP.md) (which covers installing prerequisites, `scripts\setup.ps1`,
and registering the NSSM Windows Services) and [deployment_test.md](deployment_test.md) (which
catalogues the test-branch changes). This doc covers **what is different when the
`test/railway-deployment` code runs on a Windows Server instead of Railway** — mainly each
service's environment variables, since Railway-isms (reference variables, `railway.internal`
private networking, managed volumes, `.up.railway.app` domains) don't exist on Windows.

Throughout, replace `<SERVER-IP>` with the machine's LAN IP or DNS hostname — the address other
computers use to reach it. `localhost` is only correct for service-to-service calls on the same
machine, never for URLs a browser will load.

---

## 1. How environment variables are set on Windows (no Railway dashboard)

| Service | Where its env lives |
| :--- | :--- |
| MySQL | n/a (credentials created by `scripts\setup.ps1`) |
| MinIO (`SSC-MinIO`) | NSSM `AppEnvironmentExtra` — the `-ExtraEnv @{...}` hashtable in `scripts\install-services.ps1` |
| File Server (`SSC-FileServer`) | Same — add an `-ExtraEnv` hashtable to its `Install-NssmService` call |
| Backend (`SSC-Backend`) | Same |
| Frontend (`SSC-Frontend`) | `ssc-booking-frontend\.env.local` — **`NEXT_PUBLIC_*` values are baked in at build time; rebuild (`npm run build`) after editing** |

After editing `install-services.ps1`, re-run it elevated (or use
`nssm set <ServiceName> AppEnvironmentExtra "KEY=value" "KEY2=value2"`) and restart the service.

## 2. MinIO — replaces Railway's "Bucket" service

- Runs as `SSC-MinIO` from `minio\minio.exe` (already handled by `setup.ps1` / `install-services.ps1`);
  the start arguments `server <repo>\minio\data --console-address :9001` are the Windows
  equivalent of Railway's start command + `/data` volume.
- Persistence is just the data directory on disk — put it on a disk that's backed up; no volume
  concept needed.
- **Change the default credentials** in the `-ExtraEnv` block (`MINIO_ROOT_USER` /
  `MINIO_ROOT_PASSWORD` are `sscadmin` / `sscpassword123` in the script — fine for staging, not
  for a real server).
- Do **not** set `MINIO_BROWSER_REDIRECT_URL` (the variable that crash-looped Railway's template).
- Buckets are auto-created by the fileserver at startup — no manual bucket setup.

## 3. File Server (`SSC-FileServer`) env

```
MINIO_URL         = http://localhost:9000          # same-machine service call
MINIO_PUBLIC_URL  = http://<SERVER-IP>:9000        # browsers load presigned URLs from this — MUST NOT be localhost
MINIO_ACCESS_KEY  = <MINIO_ROOT_USER value>
MINIO_SECRET_KEY  = <MINIO_ROOT_PASSWORD value>
JWT_SECRET        = <same 32+ char secret as the backend — service-to-service tokens are signed with it>
ALLOWED_ORIGINS   = http://<SERVER-IP>:3000
```

Railway's `${{Bucket.MINIO_PRIVATE_ENDPOINT}}` reference-variable syntax does not exist here —
use literal values, and keep the MinIO credentials in sync by hand.

`MINIO_PUBLIC_URL` is the #1 gotcha: if left at its `http://localhost:9000` default, every PDF
iframe/download breaks on any machine other than the server itself (same failure class as the
Railway PDF-404 incident).

Do **not** set `MINIO_URL` to anything containing `dummy` — that switches the fileserver to the
ephemeral local-disk fallback, which is a dev convenience only.

## 4. Backend (`SSC-Backend`) env

```
SPRING_DATASOURCE_URL      = jdbc:mysql://localhost:3306/ssc_booking?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
SPRING_DATASOURCE_USERNAME = sscuser            # or whatever setup.ps1 created
SPRING_DATASOURCE_PASSWORD = <db password>
JWT_SECRET                 = <same secret as fileserver, 32+ chars, not the dev default>
JWT_COOKIE_SECURE          = false              # true only if serving over HTTPS
JWT_COOKIE_SAME_SITE       = Lax                # keep Lax; "None" requires Secure=true + HTTPS
ALLOWED_ORIGINS            = http://<SERVER-IP>:3000
FILESERVER_URL             = http://localhost:8080
DEV_ENDPOINTS_ENABLED      = false
MAIL_ENABLED               = false              # set true + MAIL_USERNAME/MAIL_PASSWORD only if SMTP is allowed outbound
MANAGEMENT_HEALTH_MAIL_ENABLED = false          # skip if MAIL is enabled and SMTP reachable; otherwise health checks hang/503
```

Cookie notes: on Railway the frontend and backend were on different domains, which is why
`48e590a` made `secure`/`sameSite` configurable and the BFF proxy exists. On a single Windows
host everything is one origin family (`http://<SERVER-IP>:<port>`), so `Secure=false` +
`SameSite=Lax` is correct for plain HTTP. If you later put the stack behind an HTTPS reverse
proxy (IIS/nginx/Caddy), flip `JWT_COOKIE_SECURE=true` and update every URL in this doc to
`https://`.

## 5. Frontend (`SSC-Frontend`) — `ssc-booking-frontend\.env.local`

```
NEXT_PUBLIC_API_URL         = http://localhost:8081
NEXT_PUBLIC_FILESERVER_URL  = http://<SERVER-IP>:8080
NEXT_PUBLIC_GOOGLE_CLIENT_ID = <your OAuth client id>
```

- The test branch's BFF proxy (`app/api/[...path]/route.ts`) forwards browser requests to
  `NEXT_PUBLIC_API_URL` **server-side**, so `localhost:8081` is correct there — browsers never
  call the backend directly and port 8081 can stay firewalled.
- `NEXT_PUBLIC_FILESERVER_URL` is used by the browser → must be `<SERVER-IP>`, not localhost.
- Google OAuth: add `http://<SERVER-IP>:3000` to the authorized JavaScript origins in the Google
  Cloud console, or sign-in will fail off-machine.
- **Rebuild after any `.env.local` change** — `NEXT_PUBLIC_*` is compiled into the bundle.

## 6. Firewall / networking

Open inbound on the Windows firewall only what browsers need:

| Port | Needed by browsers? |
| :--- | :--- |
| `3000` (frontend) | Yes |
| `9000` (MinIO API) | Yes — presigned document URLs |
| `8080` (fileserver) | Yes — template/document download endpoints |
| `9001` (MinIO console) | Optional, admin only |
| `8081` (backend) | **No** — reached via the BFF proxy |
| `3306` (MySQL) | **No** |

## 7. Railway → Windows translation summary

| Railway concept | Windows equivalent |
| :--- | :--- |
| `Bucket` MinIO service + `/data` volume | `SSC-MinIO` NSSM service + `minio\data` directory |
| `${{Bucket.MINIO_ROOT_USER}}` reference vars | Literal values, kept in sync manually |
| `*.railway.internal` private networking | `localhost` between services |
| `*.up.railway.app` public domains (HTTPS) | `http://<SERVER-IP>:<port>` (+ optional reverse proxy for HTTPS) |
| Dashboard env vars | NSSM `AppEnvironmentExtra` (Java services) / `.env.local` + rebuild (frontend) |
| Auto-deploy on git push | `git pull` + `mvn package` / `npm run build` + `Restart-Service` (see SETUP.md update procedure) |
| Cross-domain cookie config (`Secure`/`SameSite=None`) | Not needed — single origin; keep `Secure=false`, `SameSite=Lax` on HTTP |

Startup order is unchanged (MySQL → MinIO → File Server → Backend → Frontend) and already
enforced by the NSSM service dependencies from `install-services.ps1`.
