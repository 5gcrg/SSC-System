# SSC Event Booking System

Paperless event management for Cor Jesu College, Inc.

## Repositories

| Folder | Stack | Port |
| ------ | ----- | ---- |
| `ssc-booking-frontend/` | Next.js 15 | 3000 |
| `ssc-booking-backend/` | Spring Boot 3 (main API) | 8081 |
| `ssc-booking-fileserver/` | Spring Boot 3 (files → MinIO) | 8080 |

Plus two infrastructure services: **MySQL 8.0** (3306) and **MinIO** (9000 API / 9001 console).

> The three app folders are **git submodules** pinned to specific commits. After pushing
> changes to an app repo, update the pin here with `git submodule update --remote <folder>`
> and commit.

## Quick Start (Windows)

```powershell
# 1. Clone with submodules
git clone --recursive https://github.com/5gcrg/SSC-System.git
cd SSC-System
# already cloned without --recursive?  git submodule update --init

# 2. One-time setup (installs prerequisites via Chocolatey, creates the DB, downloads
#    MinIO, builds all three apps). Run PowerShell as Administrator:
powershell -ExecutionPolicy Bypass -File scripts\SETUP.ps1
```

`scripts\SETUP.ps1` first checks whether Git, a JDK 21, Maven, Node.js, and MySQL are already
installed (by any method, not just Chocolatey) and only installs whatever's missing via
[Chocolatey](https://chocolatey.org/) (bootstrapping Chocolatey itself if needed). It then
provisions the `ssc_booking` database, downloads the MinIO server binary, and builds the
backend, file server, and frontend.

## Services

| Service | URL |
| ------- | --- |
| Frontend | http://localhost:3000 |
| Main API | http://localhost:8081 |
| File Server | http://localhost:8080 |
| MinIO Console | http://localhost:9001 (sscadmin / sscpassword123) |
| MySQL | localhost:3306 (`ssc_booking` / `sscuser` / `sscpassword`) |

## Running the services

```powershell
# Start everything as background processes (no per-service windows) and open a
# live status dashboard:
powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1

# Reattach to the dashboard any time (services keep running when you quit it):
powershell -ExecutionPolicy Bypass -File scripts\monitor.ps1

# Stop everything:
powershell -ExecutionPolicy Bypass -File scripts\stop-all.ps1
```

The monitor dashboard auto-refreshes and lets you restart all services, restart one specific
service, or stop all, without leaving it. Logs for each service are written to `logs\<name>.log`
/ `logs\<name>.err.log`.

## Local dev on alternate ports

The ports above are the checked-in defaults and match what the real server deployment expects —
they never change. If they clash with another project already running on your machine, override
them per-machine via a gitignored root `.env` (see the commented example block at the bottom of
`.env.example` for a ready-made 9003-9007 scheme):

```
BACKEND_PORT=9004
FILESERVER_PORT=9005
FRONTEND_PORT=9003
MINIO_PORT=9006
MINIO_CONSOLE_PORT=9007
ALLOWED_ORIGINS=http://localhost:9003,http://localhost:9004
NEXT_PUBLIC_API_URL=http://localhost:9004
NEXT_PUBLIC_FILESERVER_URL=http://localhost:9005
```

Also set `NEXT_PUBLIC_API_URL` / `NEXT_PUBLIC_FILESERVER_URL` in
`ssc-booking-frontend\.env.local` to match, then rebuild the frontend (`npm run build`) —
`NEXT_PUBLIC_*` values are baked in at build time. `scripts\ServiceLib.psm1` loads the root
`.env` into the process environment before computing each service's port and passes it through
to `start-all.ps1` / `stop-all.ps1` / `monitor.ps1` automatically; nothing else needs editing.

## Test it's running

```powershell
curl.exe http://localhost:8081/api/v1/ping        # {"status":"UP"}
curl.exe http://localhost:8080/actuator/health     # {"status":"UP"}
start http://localhost:3000/login                  # login page loads
```

## Development mode

Run infrastructure (MySQL, MinIO) as in Quick Start, but run the apps with hot reload instead
of the packaged jars:

```powershell
cd ssc-booking-frontend
npm run dev

cd ssc-booking-backend
mvn spring-boot:run

cd ssc-booking-fileserver
mvn spring-boot:run
```

## Notes

- **Database schema** is fully managed by Flyway — the first backend start creates all tables
  and seed data automatically.
- **MinIO buckets** (`ssc-documents`, `ssc-templates`, `ssc-projects`) are created
  automatically by the file server on startup.
- **External integrations** use `X-API-Key` headers: the backend exposes a read-only
  masterlist/departments/organizations surface (`MASTERLIST_CLIENT_n_*` env vars), and the
  file server exposes per-client project storage scoped to `projects/<folder>/` in
  `ssc-projects` (`PROJECT_CLIENT_n_*` env vars). See each service's README and
  `.env.example` for details.
- **JWT secret** must be identical in `ssc-booking-backend` and `ssc-booking-fileserver`
  (`app.jwt.secret` in each `application.yml`); the committed dev defaults already match.
- **Serving other computers on the network:** rebuild the frontend with the server's LAN IP in
  `ssc-booking-frontend/.env.local` (`NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_FILESERVER_URL`), add
  that IP to `app.cors.allowed-origins` in both backend `application.yml` files, and open
  inbound firewall rules for ports 3000/8080/8081/9000.
