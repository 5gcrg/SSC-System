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

`scripts\SETUP.ps1` installs Git, a JDK 21, Maven, Node.js LTS, and MySQL via
[Chocolatey](https://chocolatey.org/) (bootstrapping Chocolatey itself if it isn't already
installed), then provisions the `ssc_booking` database, downloads the MinIO server binary, and
builds the backend, file server, and frontend.

## Services

| Service | URL |
| ------- | --- |
| Frontend | http://localhost:3000 |
| Main API | http://localhost:8081 |
| File Server | http://localhost:8080 |
| MinIO Console | http://localhost:9001 (sscadmin / sscpassword123) |
| MySQL | localhost:3306 (`ssc_booking` / `sscuser` / `sscpassword`) |

## Running the services

Each service runs in its own terminal:

```powershell
minio\minio.exe server minio\data --console-address :9001
cd ssc-booking-fileserver; java -jar target\*.jar
cd ssc-booking-backend;    java -jar target\*.jar
cd ssc-booking-frontend;   npm start
```

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
- **MinIO buckets** (`ssc-documents`, `ssc-templates`) are created automatically by the file
  server on startup.
- **JWT secret** must be identical in `ssc-booking-backend` and `ssc-booking-fileserver`
  (`app.jwt.secret` in each `application.yml`); the committed dev defaults already match.
- **Serving other computers on the network:** rebuild the frontend with the server's LAN IP in
  `ssc-booking-frontend/.env.local` (`NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_FILESERVER_URL`), add
  that IP to `app.cors.allowed-origins` in both backend `application.yml` files, and open
  inbound firewall rules for ports 3000/8080/8081/9000.
