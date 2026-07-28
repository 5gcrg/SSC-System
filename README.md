# SSC Event Booking System

Paperless event management for Cor Jesu College, Inc.

## Contents

- [Repositories & architecture](#repositories--architecture)
- [Prerequisites](#prerequisites)
- [Quick Start (Windows)](#quick-start-windows)
- [Manual setup (alternative to SETUP.ps1)](#manual-setup-alternative-to-setupps1)
- [Services](#services)
- [Running the services](#running-the-services)
- [Local dev on alternate ports](#local-dev-on-alternate-ports)
- [Production deployment (Windows Server)](#production-deployment-windows-server)
- [Verifying it works](#verifying-it-works)
- [Development mode](#development-mode)
- [External API integration](#external-api-integration)
- [Troubleshooting](#troubleshooting)
- [Notes](#notes)

## Repositories & architecture

| Folder | Stack | Port | Depends on |
| ------ | ----- | ---- | ---------- |
| `ssc-booking-frontend/` | Next.js 15 (Node 22) | 3000 | Main API, File Server |
| `ssc-booking-backend/` | Spring Boot 3, Java 21 (main API) | 8081 | MySQL, File Server |
| `ssc-booking-fileserver/` | Spring Boot 3, Java 21 (files → MinIO) | 8080 | MinIO |

Plus two infrastructure services: **MySQL 8.0** (3306) and **MinIO** (9000 API / 9001 console).

> **Startup order:** MySQL → MinIO → File Server → Main API → Frontend. `scripts\start-all.ps1`
> and the NSSM service dependencies (below) already enforce this.

> The three app folders are **git submodules** pinned to specific commits. After pushing
> changes to an app repo, update the pin here with `git submodule update --remote <folder>`
> and commit.

**Branches:** `prod` is the branch reserved for real deployment (school server or local
staging) and is what this README documents. `test/railway-deployment` is Railway's test-only
branch — the production deployment does **not** run on Railway or any cloud platform used
during testing; it runs on a school-managed Windows Server. Don't use `test/railway-deployment`
for a real install.

## Prerequisites

| Software | Version | Why |
| -------- | ------- | --- |
| Git | 2.40+ | clone the repos (submodules) |
| Java JDK (Temurin) | **21** (LTS) | both Spring Boot services target Java 21 |
| Apache Maven | **3.9.x** | builds the two Spring Boot jars |
| Node.js | **22 LTS** (minimum 18.18) | Next.js 15 frontend |
| MySQL Server | **8.0.x** | database (schema is written for MySQL 8.0) |
| MinIO Server | latest `windows-amd64` | file/object storage — `scripts\SETUP.ps1` downloads this automatically |

`scripts\SETUP.ps1` (see Quick Start) installs whatever's missing via
[Chocolatey](https://chocolatey.org/), bootstrapping Chocolatey itself if needed. To install
manually instead:

**winget** (elevated PowerShell):
```powershell
winget install --id Git.Git -e
winget install --id EclipseAdoptium.Temurin.21.JDK -e
winget install --id Apache.Maven -e
winget install --id OpenJS.NodeJS.LTS -e
winget install --id Oracle.MySQL -e
```

**Chocolatey** (elevated PowerShell):
```powershell
choco install git -y
choco install temurin21 -y
choco install maven -y
choco install nodejs-lts -y
choco install mysql --version=8.0.44 -y
```
The `mysql` Chocolatey package installs MySQL as a Windows service with an **empty root
password** — pass `-MySqlRootPassword ""` to `SETUP.ps1` later. Pin to `--version=8.0.44` (or
any 8.0.x); if unavailable, use the portable-ZIP option below instead of an unpinned 9.x install.

**Manual downloads:** [Git](https://git-scm.com/download/win) ·
[Temurin JDK 21](https://adoptium.net/temurin/releases/?version=21) ·
[Maven 3.9](https://maven.apache.org/download.cgi) (unzip, add `bin` to PATH) ·
[Node.js 22 LTS](https://nodejs.org/en/download) ·
[MySQL 8.0](https://dev.mysql.com/downloads/installer/) (choose Server only; set a root
password and note it; leave port 3306; set the **MySQL80** service to auto-start) ·
[MinIO](https://dl.min.io/server/minio/release/windows-amd64/minio.exe) (or let `SETUP.ps1`
download it).

Close and reopen PowerShell after installing so `git`/`java`/`mvn`/`node`/`mysql` are on PATH.

**No admin rights / unattended automation** — portable MySQL ZIP, no installer needed (root has
no password):
```powershell
cd C:\SSC-System
Invoke-WebRequest -Uri "https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.44-winx64.zip" -OutFile mysql.zip
Expand-Archive mysql.zip -DestinationPath mysql-extract
Move-Item mysql-extract\mysql-8.0.44-winx64 mysql
Remove-Item mysql-extract, mysql.zip -Recurse -Force
.\mysql\bin\mysqld.exe --no-defaults --initialize-insecure --basedir="$PWD\mysql" --datadir="$PWD\mysql\data"

# Elevated: register as a Windows service so it survives reboots
@"
[mysqld]
basedir=$PWD\mysql
datadir=$PWD\mysql\data
port=3306
"@ | Out-File -Encoding ascii .\mysql\my.ini
.\mysql\bin\mysqld.exe --install MySQL80 --defaults-file="$PWD\mysql\my.ini"
net start MySQL80

# No admin rights: run as a plain background process instead (must be re-run after every reboot)
Start-Process .\mysql\bin\mysqld.exe -ArgumentList '--no-defaults',"--basedir=$PWD\mysql","--datadir=$PWD\mysql\data",'--console' -WindowStyle Minimized
```
With this option `mysql` is at `.\mysql\bin\mysql.exe` and root has **no password** — pass
`-MySqlRootPassword ""` to `SETUP.ps1`.

`SETUP.ps1` is interactive only for the MySQL root password — pass it as a parameter for a
zero-prompt run (automation / AI agents): `-MySqlRootPassword "yourpwd"` (or `""` for no
password). `start-all.ps1` / `stop-all.ps1` never prompt.

## Quick Start (Windows)

```powershell
# 1. Clone the `prod` branch with submodules.
git clone --recursive -b prod https://github.com/5gcrg/SSC-System.git
cd SSC-System
# already cloned without --recursive?  git submodule update --init --recursive
# cloned without -b prod?  git checkout prod && git submodule update --init --recursive

# 2. One-time setup (installs prerequisites via Chocolatey, creates the DB, downloads
#    MinIO, builds all three apps). Run PowerShell as Administrator:
powershell -ExecutionPolicy Bypass -File scripts\SETUP.ps1
```

`scripts\SETUP.ps1` first checks whether Git, a JDK 21, Maven, Node.js, and MySQL are already
installed (by any method, not just Chocolatey) and only installs whatever's missing. It then:
1. provisions the `ssc_booking` database and `sscuser` MySQL account (asks for your MySQL
   **root** password once, unless passed as `-MySqlRootPassword`),
2. downloads `minio.exe` into `.tools\` if missing,
3. builds both Spring Boot jars (`mvn clean package -DskipTests`),
4. installs frontend dependencies and creates `.env.local` (from `.env.local.example`) if missing,
5. builds the production frontend (`npm run build`).

## Manual setup (alternative to SETUP.ps1)

If you'd rather not run the automated script, or it fails partway:

**Database**
```powershell
mysql -u root -p
```
```sql
CREATE DATABASE IF NOT EXISTS ssc_booking CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'sscuser'@'localhost' IDENTIFIED BY 'sscpassword';
CREATE USER IF NOT EXISTS 'sscuser'@'%' IDENTIFIED BY 'sscpassword';
GRANT ALL PRIVILEGES ON ssc_booking.* TO 'sscuser'@'localhost';
GRANT ALL PRIVILEGES ON ssc_booking.* TO 'sscuser'@'%';
FLUSH PRIVILEGES;
EXIT;
```
Tables and seed data are created automatically by Flyway on the first backend start — no SQL
dump needed.

**MinIO**
```powershell
mkdir C:\SSC-System\.tools
Invoke-WebRequest -Uri "https://dl.min.io/server/minio/release/windows-amd64/minio.exe" -OutFile "C:\SSC-System\.tools\minio.exe"
```
Buckets (`ssc-documents`, `ssc-templates`, `ssc-projects`) are created automatically by the file
server on startup — no manual bucket setup.

**Build the jars**
```powershell
cd C:\SSC-System\ssc-booking-backend
mvn clean package -DskipTests          # -> target\ssc-booking-backend-1.0.0-SNAPSHOT.jar

cd C:\SSC-System\ssc-booking-fileserver
mvn clean package -DskipTests          # -> target\ssc-booking-0.0.1-SNAPSHOT.jar
```

**Frontend**
```powershell
cd C:\SSC-System\ssc-booking-frontend
copy .env.local.example .env.local
npm install
npm run build
```
`.env.local` defaults work for same-machine access:
```
NEXT_PUBLIC_API_URL=http://localhost:8081
NEXT_PUBLIC_FILESERVER_URL=http://localhost:8080
NEXT_PUBLIC_GOOGLE_CLIENT_ID=<your Google OAuth client id>
```

**Manual startup (four separate PowerShell windows, instead of `start-all.ps1`)**

Window 1 — MinIO:
```powershell
$env:MINIO_ROOT_USER = "sscadmin"
$env:MINIO_ROOT_PASSWORD = "sscpassword123"
C:\SSC-System\.tools\minio.exe server C:\SSC-System\.tools\minio-data --console-address ":9001"
```
Window 2 — File Server (wait for MinIO's startup banner first):
```powershell
cd C:\SSC-System\ssc-booking-fileserver
java -jar target\ssc-booking-0.0.1-SNAPSHOT.jar
```
Window 3 — Main API (needs MySQL running + File Server up):
```powershell
cd C:\SSC-System\ssc-booking-backend
java -jar target\ssc-booking-backend-1.0.0-SNAPSHOT.jar
```
Window 4 — Frontend:
```powershell
cd C:\SSC-System\ssc-booking-frontend
npm run start        # production build on port 3000
# or during development:  npm run dev
```

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

## Production deployment (Windows Server)

Quick Start above runs the services as plain background processes — fine for a demo, but they
won't survive a reboot or restart automatically after a crash. For a real Windows Server,
register the four app services with [NSSM](https://nssm.cc/) instead:

```powershell
# Elevated PowerShell, after completing Quick Start above (so the jars/build already exist)
powershell -ExecutionPolicy Bypass -File scripts\install-services.ps1

# To remove them again:
powershell -ExecutionPolicy Bypass -File scripts\uninstall-services.ps1
```

This downloads `nssm.exe` into `nssm\` if missing, registers `SSC-MinIO`, `SSC-FileServer`,
`SSC-Backend`, `SSC-Frontend` as Windows Services with the correct startup order/dependencies
(MySQL → MinIO → File Server → Backend → Frontend) and auto-start on boot. MySQL is untouched
(already its own native Windows service). Check status anytime with `scripts\monitor.ps1` or
`services.msc`. Logs go to `logs\ssc-<name>.log` / `logs\ssc-<name>.err.log`. Don't run
`scripts\start-all.ps1` at the same time as the installed services — they'd fight over the same
ports; use one or the other.

**Simpler alternative (no restart-on-crash):** register a Task Scheduler entry that runs
`start-all.ps1` at boot instead of real services:
```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
           -Argument "-ExecutionPolicy Bypass -File C:\SSC-System\scripts\start-all.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "SSC-System" -Action $action -Trigger $trigger `
    -RunLevel Highest -User "SYSTEM"
```

### Environment variables a real server needs (vs. the `localhost` dev defaults)

`localhost` is only correct for service-to-service calls on the same machine, never for URLs a
browser will load. Replace `<SERVER-IP>` below with the machine's LAN IP or DNS hostname.

Set these via NSSM's `AppEnvironmentExtra` (the `-ExtraEnv` hashtable in
`scripts\install-services.ps1` for MinIO/File Server/Backend), or `ssc-booking-frontend\.env.local`
for the frontend. After editing `install-services.ps1`, re-run it elevated (or
`nssm set <ServiceName> AppEnvironmentExtra "KEY=value" "KEY2=value2"`) and restart the service.

**MinIO** — change the default credentials (`MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`, `sscadmin`/
`sscpassword123` by default — fine for staging, not for a real server). Do **not** set
`MINIO_BROWSER_REDIRECT_URL`. Buckets are auto-created by the fileserver at startup.

**File Server:**
```
MINIO_URL         = http://localhost:9000          # same-machine service call
MINIO_PUBLIC_URL  = http://<SERVER-IP>:9000        # browsers load presigned URLs from this — MUST NOT be localhost
MINIO_ACCESS_KEY  = <MINIO_ROOT_USER value>
MINIO_SECRET_KEY  = <MINIO_ROOT_PASSWORD value>
JWT_SECRET        = <same 32+ char secret as the backend — service-to-service tokens are signed with it>
ALLOWED_ORIGINS   = http://<SERVER-IP>:3000
```
`MINIO_PUBLIC_URL` is the #1 gotcha: if left at its `localhost` default, every PDF iframe/download
breaks on any machine other than the server itself. Do **not** set `MINIO_URL` to anything
containing `dummy` — that switches the fileserver to the ephemeral local-disk fallback, a dev
convenience only.

**Backend:**
```
SPRING_DATASOURCE_URL      = jdbc:mysql://localhost:3306/ssc_booking?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
SPRING_DATASOURCE_USERNAME = sscuser
SPRING_DATASOURCE_PASSWORD = <db password>
JWT_SECRET                 = <same secret as fileserver, 32+ chars, not the dev default>
JWT_COOKIE_SECURE          = false              # true only if serving over HTTPS
JWT_COOKIE_SAME_SITE       = Lax                # keep Lax; "None" requires Secure=true + HTTPS
ALLOWED_ORIGINS            = http://<SERVER-IP>:3000
FILESERVER_URL             = http://localhost:8080
DEV_ENDPOINTS_ENABLED      = false
MAIL_ENABLED               = false              # true + MAIL_USERNAME/MAIL_PASSWORD only if SMTP is allowed outbound
MANAGEMENT_HEALTH_MAIL_ENABLED = false          # skip if MAIL is enabled and SMTP reachable; otherwise health checks hang/503
```
On a single Windows host everything is one origin family (`http://<SERVER-IP>:<port>`), so
`Secure=false` + `SameSite=Lax` is correct for plain HTTP. If you later put the stack behind an
HTTPS reverse proxy (IIS/nginx/Caddy), flip `JWT_COOKIE_SECURE=true` and use `https://` throughout.

**Frontend** (`ssc-booking-frontend\.env.local`, rebuild with `npm run build` after any change —
`NEXT_PUBLIC_*` is compiled into the bundle):
```
NEXT_PUBLIC_API_URL         = http://localhost:8081
NEXT_PUBLIC_FILESERVER_URL  = http://<SERVER-IP>:8080
NEXT_PUBLIC_GOOGLE_CLIENT_ID = <your OAuth client id>
```
The BFF proxy (`app/api/[...path]/route.ts`) forwards browser requests to `NEXT_PUBLIC_API_URL`
**server-side**, so `localhost:8081` is correct there — browsers never call the backend directly
and port 8081 can stay firewalled. `NEXT_PUBLIC_FILESERVER_URL` is used by the browser → must be
`<SERVER-IP>`, not localhost. Add `http://<SERVER-IP>:3000` to the Google OAuth client's
authorized JavaScript origins, or sign-in will fail off-machine.

**Firewall** — open inbound only what browsers need:

| Port | Needed by browsers? |
| :--- | :--- |
| `3000` (frontend) | Yes |
| `9000` (MinIO API) | Yes — presigned document URLs |
| `8080` (fileserver) | Yes — template/document download endpoints |
| `9001` (MinIO console) | Optional, admin only |
| `8081` (backend) | **No** — reached via the BFF proxy |
| `3306` (MySQL) | **No** |

```powershell
New-NetFirewallRule -DisplayName "SSC Frontend"   -Direction Inbound -LocalPort 3000 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "SSC Main API"   -Direction Inbound -LocalPort 8081 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "SSC FileServer" -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "SSC MinIO"      -Direction Inbound -LocalPort 9000 -Protocol TCP -Action Allow
```

### Updating to the latest code

```powershell
cd C:\SSC-System
git pull
git submodule update --init --remote

cd ssc-booking-backend    ; mvn clean package -DskipTests
cd ..\ssc-booking-fileserver ; mvn clean package -DskipTests
cd ..\ssc-booking-frontend   ; npm install ; npm run build
```
Then restart the services (`scripts\stop-all.ps1` + `scripts\start-all.ps1`, or
`Restart-Service SSC-*` if installed as NSSM services). Flyway applies any new database
migrations automatically on backend start.

## Verifying it works

```powershell
curl.exe http://localhost:8081/api/v1/ping        # {"status":"UP"}
curl.exe http://localhost:8080/actuator/health     # {"status":"UP"}
start http://localhost:3000/login                  # login page loads
start http://localhost:9001                        # MinIO console (sscadmin / sscpassword123)
```
The first backend start runs all Flyway migrations — check `logs\backend.log` for `Successfully
applied ... migrations`.

**Integration test matrix** — `scripts\test-integration-matrix.sh` (run from Git Bash) exercises
the full external-integration surface (auth, rate limiting, path-traversal guards, pagination,
cross-client isolation — see [External API integration](#external-api-integration) below) against
a running stack and prints PASS/FAIL per check plus a summary. It expects these **throwaway test
keys** configured server-side (via env vars, not the real client keys in the table below):
```
Backend:     MASTERLIST_API_KEY=legacy-key-0000111122223333          # slot-1 legacy fallback, allow-sensitive=false
             MASTERLIST_CLIENT_2_NAME=sensitive-app
             MASTERLIST_CLIENT_2_KEY=test-key-s-aaaabbbbccccdddd
             MASTERLIST_CLIENT_2_ALLOW_SENSITIVE=true
Fileserver:  PROJECT_CLIENT_1 = acme / test-key-a-0123456789abcdef / folder acme-app
             PROJECT_CLIENT_2 = beta / test-key-b-fedcba9876543210 / folder beta-app
```
If your `.env` has the real `clearance-system`/`clinic-system` keys instead (the normal case for
a real deployment), the script's key-gated checks will fail with `API_KEY_INVALID` — that's
expected and not a bug; either run it against a throwaway `.env` with the keys above, or ignore
the key-gated failures and treat the auth/traversal/health checks as the signal.

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

## External API integration

Two independent read/write surfaces let external systems (e.g. the school's Clearance System and
Clinic System) integrate machine-to-machine, on two different services with two **separate** API
key registries — a key issued for one does not work on the other. Neither is meant for browser
JavaScript: the file server's integration path has no CORS configuration at all, by design; the
backend's integration path is covered by its general CORS policy but is still intended to be
called server-to-server.

| Service | Purpose | Base URL (dev) | Auth header |
|---|---|---|---|
| Backend (`ssc-booking-backend`) | Read-only masterlist / departments / organizations data | `http://localhost:8081` | `X-API-Key` |
| File Server (`ssc-booking-fileserver`) | Scoped file storage (own folder only) | `http://localhost:8080` | `X-API-Key` |

Each service keeps a fixed registry of **up to 3 client slots**, configured via env vars:
Backend `MASTERLIST_CLIENT_n_NAME` / `_KEY` / `_ALLOW_SENSITIVE` (n = 1–3); File Server
`PROJECT_CLIENT_n_NAME` / `_KEY` / `_FOLDER` (n = 1–3). `NAME` is a label logged on every access
(keys are never logged). `ALLOW_SENSITIVE` gates `includeSensitive=true` on masterlist reads.
`FOLDER` is the subfolder under `projects/` in the `ssc-projects` bucket a file-server key is
permanently confined to. A slot with a blank `KEY` is ignored. Both registries validate at
startup: bad/unsafe folders, duplicate names, or duplicate keys fail the service to start.
Rotating a key requires a service restart.

### Current client credentials

> **These are live keys.** Treat this table as sensitive — do not paste it into a public channel
> or forward it outside the teams it's issued to. If a key ever leaks, rotate it immediately
> (issue a new one in the relevant `.env`/NSSM env and restart the service).

| | Clearance System | Clinic System |
|---|---|---|
| Client name | `clearance-system` | `clinic-system` |
| Backend `X-API-Key` | `064f4002044e257d5410bc0fb0a31d091a4a06c7a530e30e0c08b5c011b73b54` | `326bcd86b8a63778f42289729eede712f47e356478fad0092fd47e975dc2ab7f` |
| Sensitive masterlist fields | Allowed | Allowed |
| File Server `X-API-Key` | `f7d2b66d3664739181b4eed50cd05d9687918b10780936cd4e611fed3836f1c3` | `4317dd5f832e3bd24c1ec55723b05531415ef51a4b7ab684058bc2725b0c7e09` |
| File server folder | `projects/clearance-system/` | `projects/clinic-system/` |

Send the key on **every request** as the `X-API-Key` header. The folder is informational only —
you never put it in a request; the file server confines the key to it automatically. These are
dev/local-environment keys; production credentials are issued separately (see below).

### Backend integration API (`/api/v1/integration/**`)

**Strictly read-only** — any non-GET request returns `405`, even with a valid key.

**Masterlist**

| Method | Path | Query params |
|---|---|---|
| GET | `/api/v1/integration/masterlist` | `includeSensitive` (bool, default `false`) |
| GET | `/api/v1/integration/masterlist/{studentId}` | `includeSensitive` (bool, default `false`) |

Response: `MasterlistStudentResponse` (list endpoint returns an array).

- **Always present:** `studentId`, `familyName`, `givenName`, `middleName`, `suffix`, `fullName`,
  `email`, `departmentId`, `program`, `major`, `yearLevel`, `academicStatus`, `studentType`,
  `contactNumber`, `isActive`
- **Sensitive** (`null` unless `includeSensitive=true` **and** the key has `ALLOW_SENSITIVE=true`,
  else `403`): `dateOfBirth`, `placeOfBirth`, `sex`, `civilStatus`, `religion`,
  `permanentAddress`, `currentAddress`, `guardianName`, `guardianContactNumber`,
  `emergencyContactName`, `emergencyContactNumber`

**Departments** — `GET /api/v1/integration/departments` (active only), `GET .../{id}`.
`DepartmentResponse`: `departmentId`, `name`, `code`, `collegeName`, `isActive`, `createdAt`.

**Organizations** — `GET /api/v1/integration/organizations` (`departmentId`, `active` bool,
`category` ∈ `ACADEMIC`/`NON_ACADEMIC`/`ACCO`/`CSG`), `GET .../{id}`.
`OrganizationResponse`: `orgId`, `name`, `acronym`, `departmentId`, `departmentName`,
`departmentCode`, `category`, `isActive`, `createdAt`.

**Rate limiting:** 30 req/min per key by default (bucket keyed by a hash of the key, so
invalid-key brute-forcing is throttled too). Env knobs: `RATE_LIMIT_INTEGRATION_CAPACITY`,
`RATE_LIMIT_INTEGRATION_REFILL_TOKENS`, `RATE_LIMIT_INTEGRATION_REFILL_PERIOD_SECONDS`.

**Errors** (auth/rate-limit failures use a simple inline shape, no `path`/`details`):
```json
{ "status": 401, "error": "Unauthorized", "message": "Missing X-API-Key header.", "timestamp": "2026-07-27T10:15:30.123456" }
```
| Status | `error` | `message` | When |
|---|---|---|---|
| 401 | `Unauthorized` | `Integration API key is not configured.` | No clients configured server-side |
| 401 | `Unauthorized` | `Missing X-API-Key header.` | Header absent/blank |
| 403 | `Forbidden` | `Invalid API key.` | Header doesn't match any client |
| 403 | `Forbidden` | `This client is not permitted to read sensitive fields.` | `includeSensitive=true` without capability |
| 405 | `Method Not Allowed` | `The integration API is read-only.` | Non-GET request |
| 429 | `Too Many Requests` | `Rate limit exceeded. Please try again later.` | Also sets `Retry-After: <seconds>` |

A `404` for an unknown `{id}` uses the app's general error shape instead (includes `path`/`details`).

### File Server project-storage API (`/api/v1/integration/files`)

Every operation is confined to `projects/<your-folder>/…` in the `ssc-projects` bucket — the
folder is applied automatically, never supplied by the caller. Paths always travel as
query/form parameters, never in the URL path (so slashes survive intact).

**Upload / overwrite:**
```
POST /api/v1/integration/files   (multipart/form-data: file=<binary>, path=builds/v1.2/app.zip)
→ 201 { "key", "size", "contentType", "overwritten", "uploadedAt" }
```
**Presigned download URL:**
```
GET /api/v1/integration/files/url?path=builds/v1.2/app.zip
→ 200 { "presignedUrl", "expiresAt", "expiresInSeconds" }
```
Fetch directly from `presignedUrl` (bytes never proxy through the app). Signed against the
server's `MINIO_PUBLIC_URL` — that host must be reachable from the caller's network, not just the
file server's own machine. `404 FILE_NOT_FOUND` if the path doesn't exist.

**List:**
```
GET /api/v1/integration/files?prefix=builds/&maxKeys=100&startAfter=<relative-key>
→ 200 { "files": [{ "key", "size", "lastModified", "etag" }], "truncated", "nextStartAfter" }
```
All params optional. `maxKeys` defaults to 100, capped at 1000. When `truncated` is `true`, repeat
with `startAfter=<nextStartAfter>` for the next page.

**Delete:**
```
DELETE /api/v1/integration/files?path=builds/v1.2/app.zip
→ 204 No Content   (always — deleting a nonexistent path is also 204, idempotent by design)
```

**Path rules** — rejected outright with `403 PATH_VIOLATION`: leading/trailing/double `/`,
backslashes, `%` or control characters, a segment of `.`/`..`/blank, >512 chars total, or >20
segments. Otherwise the server sanitizes rather than rejects: disallowed characters in a segment
become `_`, and the filename segment is truncated at 200 chars — treat the `key` in the response
as canonical, it may differ from the `path` sent.

**Limits:** max file size 25 MB (`MAX_PROJECT_FILE_SIZE_MB`, must stay under the service's 50 MB
hard ceiling). Blocked extensions (`400`): `exe, dll, msi, bat, cmd, com, scr, pif, vbs, ps1, sh`
— everything else allowed, since files are only ever served via presigned MinIO URLs, never the
app's own origin. The declared `Content-Type` is stored/echoed but never trusted for validation.

**Rate limiting:** 60 req/min per client by default. Env knobs:
`INTEGRATION_RATE_LIMIT_CAPACITY`, `INTEGRATION_RATE_LIMIT_REFILL_TOKENS`,
`INTEGRATION_RATE_LIMIT_REFILL_PERIOD_SECONDS`.

**Errors** (one consistent shape):
```json
{ "code": "PATH_VIOLATION", "message": "Invalid file path.", "status": 403, "timestamp": "2026-07-27T10:15:30.123456Z" }
```
| Status | `code` | When |
|---|---|---|
| 401 | `NOT_CONFIGURED` | No clients configured server-side |
| 401 | `API_KEY_MISSING` | Header absent/blank |
| 403 | `API_KEY_INVALID` | Header doesn't match any client |
| 403 | `PATH_VIOLATION` | `path`/`prefix` failed sanitization, or cross-folder attempt |
| 400 | `FILE_VALIDATION_ERROR` | Missing file, blocked extension, etc. |
| 400 | `FILE_TOO_LARGE` | Over the 25 MB cap |
| 404 | `FILE_NOT_FOUND` | Presigned-URL request for a path that doesn't exist |
| 429 | `RATE_LIMITED` | Also sets `Retry-After: <seconds>` |
| 500 | `FILE_STORAGE_ERROR` | Unexpected server-side storage failure |

Another client's files are invisible, not merely blocked — listing never shows them, and a
presigned-URL request for a path you don't own is `404`, not `403`.

### Worked examples

Reference the key via an env var rather than hardcoding it into source you might commit.

**curl:**
```bash
curl -H "X-API-Key: $MASTERLIST_KEY" "http://localhost:8081/api/v1/integration/masterlist"
curl -H "X-API-Key: $MASTERLIST_KEY" "http://localhost:8081/api/v1/integration/masterlist/2023-00123?includeSensitive=true"
curl -H "X-API-Key: $MASTERLIST_KEY" "http://localhost:8081/api/v1/integration/departments"
curl -H "X-API-Key: $MASTERLIST_KEY" "http://localhost:8081/api/v1/integration/organizations?active=true&category=ACADEMIC"

curl -X POST -H "X-API-Key: $PROJECT_KEY" -F "file=@./app.zip" -F "path=builds/v1.2/app.zip" \
  "http://localhost:8080/api/v1/integration/files"
curl -H "X-API-Key: $PROJECT_KEY" "http://localhost:8080/api/v1/integration/files/url?path=builds/v1.2/app.zip"
curl -H "X-API-Key: $PROJECT_KEY" "http://localhost:8080/api/v1/integration/files?prefix=builds/&maxKeys=2"
curl -X DELETE -H "X-API-Key: $PROJECT_KEY" "http://localhost:8080/api/v1/integration/files?path=builds/v1.2/app.zip"
```

**Node.js (fetch):**
```javascript
const BACKEND = "http://localhost:8081";
const FILESERVER = "http://localhost:8080";

async function getDepartments() {
  const res = await fetch(`${BACKEND}/api/v1/integration/departments`, {
    headers: { "X-API-Key": process.env.MASTERLIST_API_KEY },
  });
  if (!res.ok) throw new Error(`Departments fetch failed: ${res.status}`);
  return res.json();
}

async function uploadFile(localPath, remotePath) {
  const form = new FormData();
  form.append("file", new Blob([await fs.promises.readFile(localPath)]));
  form.append("path", remotePath);
  const res = await fetch(`${FILESERVER}/api/v1/integration/files`, {
    method: "POST",
    headers: { "X-API-Key": process.env.PROJECT_API_KEY },
    body: form,
  });
  if (!res.ok) throw new Error(`Upload failed: ${res.status} ${await res.text()}`);
  return res.json();
}

async function listAll(prefix) {
  let startAfter, all = [];
  do {
    const url = new URL(`${FILESERVER}/api/v1/integration/files`);
    url.searchParams.set("prefix", prefix);
    if (startAfter) url.searchParams.set("startAfter", startAfter);
    const res = await fetch(url, { headers: { "X-API-Key": process.env.PROJECT_API_KEY } });
    const page = await res.json();
    all.push(...page.files);
    startAfter = page.truncated ? page.nextStartAfter : undefined;
  } while (startAfter);
  return all;
}
```

### Going to production

The base URLs above (`localhost:8081` / `localhost:8080`) are for local dev/testing only —
production runs on the school-managed server described in
[Production deployment](#production-deployment-windows-server), not on any cloud platform used
during testing. Confirm the real hostname/port/TLS with the SSC system admin before pointing a
live integration at it. **Production credentials are issued separately from the dev keys above —
don't reuse them in production.** To rotate a key, issue a new one in the relevant `_KEY` env var
and restart the service; the old key stops working immediately (registries validate at startup).

### Quick reference

| Method | Path | Service | Purpose |
|---|---|---|---|
| GET | `/api/v1/integration/masterlist` | Backend | List students |
| GET | `/api/v1/integration/masterlist/{studentId}` | Backend | One student |
| GET | `/api/v1/integration/departments` | Backend | List departments |
| GET | `/api/v1/integration/departments/{id}` | Backend | One department |
| GET | `/api/v1/integration/organizations` | Backend | List organizations |
| GET | `/api/v1/integration/organizations/{id}` | Backend | One organization |
| POST | `/api/v1/integration/files` | File Server | Upload/overwrite a file |
| GET | `/api/v1/integration/files/url` | File Server | Get a presigned download URL |
| GET | `/api/v1/integration/files` | File Server | List your files |
| DELETE | `/api/v1/integration/files` | File Server | Delete a file |

## Troubleshooting

| Problem | Fix |
| ------- | --- |
| `Port 8081 was already in use` | Another copy is running — `scripts\stop-all.ps1`, or `netstat -ano \| findstr :8081` and `taskkill /PID <pid> /F` |
| Backend exits with `Access denied for user 'sscuser'` | Re-run the database SQL above; confirm with `mysql -u sscuser -psscpassword ssc_booking -e "SELECT 1;"` |
| Backend exits with Flyway `Migration checksum mismatch` | DB was created by a different code version — for a dev/demo DB, `DROP DATABASE ssc_booking;`, recreate it, restart the backend (Flyway reapplies all migrations; this deletes all data) |
| File server: `MinIO ... Connection refused` | MinIO isn't running — start it first, check `logs\minio.log` |
| Frontend shows "Network error" | Main API isn't up on 8081, or `NEXT_PUBLIC_API_URL` points at the wrong host (rebuild after editing `.env.local`) |
| Google sign-in rejected | The frontend origin isn't in the OAuth client's authorized JavaScript origins |
| `mvn` / `java` / `node` not recognized | Reopen PowerShell after installing, or add the install folder to PATH |
| Logout / session expires after a week | By design — JWT lifespan is 7 days (`app.jwt.expiration` in the backend `application.yml`) |

## Notes

- **Database schema** is fully managed by Flyway — the first backend start creates all tables
  and seed data automatically.
- **MinIO buckets** (`ssc-documents`, `ssc-templates`, `ssc-projects`) are created
  automatically by the file server on startup.
- **JWT secret** must be identical in `ssc-booking-backend` and `ssc-booking-fileserver`
  (`app.jwt.secret` in each `application.yml`); the committed dev defaults already match.
