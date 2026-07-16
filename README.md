# SSC Event Booking System

Paperless event management for Cor Jesu College, Inc.

## Repositories

| Folder | Stack | Port |
| ------ | ----- | ---- |
| `ssc-booking-frontend/` | Next.js 15 | 3000 |
| `ssc-booking-backend/` | Spring Boot 3 (main API) | 8081 |
| `ssc-booking-fileserver/` | Spring Boot 3 (files → MinIO) | 8080 |

Plus two infrastructure services: **MySQL 8.0** (3306) and **MinIO** (9000/9001).

> The three app folders are **git submodules** pinned to specific commits:
> `5gcrg/SSC-Event-System`, `5gcrg/SSC-Event-System-Backend`, and
> `Radzuuuu/expert-funicular`. After pushing changes to an app repo, update the
> pin here with `git submodule update --remote <folder>` and commit.

## Quick Start (Windows, no Docker)

Full guide with versions and manual steps: **[INSTRUCTIONS.md](INSTRUCTIONS.md)**

```powershell
# 0. Prerequisites (see INSTRUCTIONS.md §1):
#    Git, Temurin JDK 21, Maven 3.9, Node.js 22 LTS, MySQL Server 8.0

# 1. Clone
git clone --recursive https://github.com/5gcrg/SSC-System.git
cd SSC-System
# already cloned without --recursive?  git submodule update --init

# 2. One-time setup (DB + MinIO download + builds; asks for MySQL root password)
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

# 3. Start everything (one window per service)
powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1

# Stop everything
powershell -ExecutionPolicy Bypass -File scripts\stop-all.ps1
```

## Services

| Service | URL |
| ------- | --- |
| Frontend | http://localhost:3000 |
| Main API | http://localhost:8081 |
| File Server | http://localhost:8080 |
| MinIO Console | http://localhost:9001 (sscadmin / sscpassword123) |
| MySQL | localhost:3306 (ssc_booking / sscuser / sscpassword) |

## Test it's running

```powershell
curl.exe http://localhost:8081/api/v1/ping        # {"status":"UP"}
curl.exe http://localhost:8080/actuator/health    # {"status":"UP"}
start http://localhost:3000/login                 # login page loads
```

## Development mode

Run infrastructure + jars as in the Quick Start, but run the frontend with
hot reload:

```powershell
cd ssc-booking-frontend
npm run dev
```

Backend with hot restart (instead of the packaged jar):

```powershell
cd ssc-booking-backend
mvn spring-boot:run
```

## Notes

- **Database schema** is fully managed by Flyway — the first backend start
  creates all tables and seed data automatically.
- **MinIO buckets** (`ssc-documents`, `ssc-templates`) are created
  automatically by the file server on startup.
- **JWT secret** must be identical in `ssc-booking-backend` and
  `ssc-booking-fileserver` (`app.jwt.secret` in each `application.yml`);
  the committed dev defaults already match.
- **Serving other computers on the network:** see INSTRUCTIONS.md §6 —
  the frontend must be rebuilt with the server's IP, CORS allow-lists
  updated, and firewall ports opened.
- The old Docker files (`docker-compose.*.yml`, `Dockerfile`s) are kept in
  the repos but are **no longer the supported way to run the system**.
