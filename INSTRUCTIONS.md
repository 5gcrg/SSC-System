# SSC Event Booking System — Windows Server Setup (No Docker)

Step-by-step guide to install and run the whole system directly on a
Windows Server virtual machine (also works on Windows 10/11).

## Architecture

| Service | Technology | Port | Depends on |
| ------- | ---------- | ---- | ---------- |
| MySQL | MySQL Server 8.0 | 3306 | — |
| MinIO | MinIO object storage | 9000 (API), 9001 (console) | — |
| File Server | Spring Boot (`ssc-booking-fileserver/`) | 8080 | MinIO |
| Main API | Spring Boot (`ssc-booking-backend/`) | 8081 | MySQL, File Server |
| Frontend | Next.js (`ssc-booking-frontend/`) | 3000 | Main API, File Server |

Start order: **MySQL → MinIO → File Server → Main API → Frontend**

---

## 1. Install prerequisites

Install these exact major versions (newer minor/patch releases are fine):

| Software | Version | Why |
| -------- | ------- | --- |
| Git | 2.40+ | clone the repos (submodules) |
| Java JDK (Temurin) | **21** (LTS) | both Spring Boot services target Java 21 |
| Apache Maven | **3.9.x** | builds the two Spring Boot jars |
| Node.js | **22 LTS** (minimum 18.18) | Next.js 15 frontend |
| MySQL Server | **8.0.x** | database (schema is written for MySQL 8.0) |
| MinIO Server | latest `windows-amd64` | file/object storage |

### Option A — winget (fastest, run in an **elevated** PowerShell)

```powershell
winget install --id Git.Git -e
winget install --id EclipseAdoptium.Temurin.21.JDK -e
winget install --id Apache.Maven -e
winget install --id OpenJS.NodeJS.LTS -e
winget install --id Oracle.MySQL -e
```

Close and reopen PowerShell afterwards so `java`, `mvn`, `node`, `npm`,
and `mysql` are on PATH. Verify:

```powershell
java -version    # openjdk 21.x (or newer)
mvn -version     # Apache Maven 3.9.x
node --version   # v22.x (or v18.18+)
mysql --version  # mysql  Ver 8.0.x
```

### Option B — manual downloads

- Git: https://git-scm.com/download/win
- Temurin JDK 21: https://adoptium.net/temurin/releases/?version=21
- Maven 3.9: https://maven.apache.org/download.cgi (unzip, add `bin` to PATH)
- Node.js 22 LTS: https://nodejs.org/en/download
- MySQL 8.0: https://dev.mysql.com/downloads/installer/ (choose **Server only**;
  set a root password during install and note it down; leave port 3306;
  make sure the **MySQL80** Windows service is set to start automatically)
- MinIO: the setup script downloads `minio.exe` automatically, or grab it from
  https://dl.min.io/server/minio/release/windows-amd64/minio.exe

> **MySQL note:** if `mysql` is not on PATH after installing, add
> `C:\Program Files\MySQL\MySQL Server 8.0\bin` to the system PATH.

---

## 2. Clone the repository

```powershell
cd C:\
git clone --recursive https://github.com/5gcrg/SSC-System.git
cd SSC-System

# if you cloned without --recursive:
git submodule update --init
```

The three app folders (`ssc-booking-frontend/`, `ssc-booking-backend/`,
`ssc-booking-fileserver/`) are git submodules and must not be empty.

---

## 3. One-time setup

### Option A — scripted (recommended)

```powershell
cd C:\SSC-System
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
```

The script will:
1. verify all prerequisites are installed,
2. create the `ssc_booking` database and `sscuser` MySQL account
   (it asks for your MySQL **root** password once),
3. download `minio.exe` into `minio\` if missing,
4. build both Spring Boot jars (`mvn clean package -DskipTests`),
5. install frontend dependencies and create `.env.local`,
6. build the production frontend (`npm run build`).

### Option B — manual

**3.1 Database**

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

Tables and seed data are created automatically by Flyway on the first
backend start — no SQL dump needed.

**3.2 MinIO**

```powershell
mkdir C:\SSC-System\minio
mkdir C:\SSC-System\minio\data
Invoke-WebRequest -Uri "https://dl.min.io/server/minio/release/windows-amd64/minio.exe" -OutFile "C:\SSC-System\minio\minio.exe"
```

Buckets (`ssc-documents`, `ssc-templates`) are created automatically by the
file server on startup — no manual bucket setup.

**3.3 Build the backend jars**

```powershell
cd C:\SSC-System\ssc-booking-backend
mvn clean package -DskipTests          # -> target\ssc-booking-backend-1.0.0-SNAPSHOT.jar

cd C:\SSC-System\ssc-booking-fileserver
mvn clean package -DskipTests          # -> target\ssc-booking-0.0.1-SNAPSHOT.jar
```

**3.4 Frontend**

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

---

## 4. Running the system

### Option A — scripted (recommended)

```powershell
cd C:\SSC-System
powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1
```

Opens one window per service (MinIO → File Server → Main API → Frontend),
waiting for each dependency to come up first. MySQL runs as the
**MySQL80** Windows service and is started automatically if stopped.

To stop everything:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\stop-all.ps1
```

### Option B — manual (four separate PowerShell windows)

**Window 1 — MinIO**

```powershell
$env:MINIO_ROOT_USER = "sscadmin"
$env:MINIO_ROOT_PASSWORD = "sscpassword123"
C:\SSC-System\minio\minio.exe server C:\SSC-System\minio\data --console-address ":9001"
```

**Window 2 — File Server** (wait until MinIO prints its startup banner)

```powershell
cd C:\SSC-System\ssc-booking-fileserver
java -jar target\ssc-booking-0.0.1-SNAPSHOT.jar
```

**Window 3 — Main API** (needs MySQL running + File Server up)

```powershell
cd C:\SSC-System\ssc-booking-backend
java -jar target\ssc-booking-backend-1.0.0-SNAPSHOT.jar
```

**Window 4 — Frontend**

```powershell
cd C:\SSC-System\ssc-booking-frontend
npm run start        # production build on port 3000
# or during development:  npm run dev
```

---

## 5. Verify it's running

```powershell
curl.exe http://localhost:8080/actuator/health     # {"status":"UP"}   (file server)
curl.exe http://localhost:8081/api/v1/ping         # {"status":"UP"}   (main API)
start http://localhost:3000/login                  # login page loads  (frontend)
start http://localhost:9001                        # MinIO console (sscadmin / sscpassword123)
```

The first backend start runs all Flyway migrations — check its window for
`Successfully applied ... migrations`.

---

## 6. Accessing from other computers (LAN)

The defaults are for browsing **on the server itself**. To let other
machines on the network use the system:

1. Rebuild the frontend with the server's IP baked in
   (`NEXT_PUBLIC_*` values are fixed at build time):

   ```
   # ssc-booking-frontend\.env.local
   NEXT_PUBLIC_API_URL=http://<SERVER-IP>:8081
   NEXT_PUBLIC_FILESERVER_URL=http://<SERVER-IP>:8080
   ```
   then `npm run build` again.

2. Add the frontend origin to CORS allow-lists:
   - `ssc-booking-backend\src\main\resources\application.yml` →
     `app.cors.allowed-origins` → add `http://<SERVER-IP>:3000`
   - `ssc-booking-fileserver\src\main\resources\application.yml` →
     `app.cors.allowed-origins` → add `http://<SERVER-IP>:3000`
   then rebuild both jars.

3. Open the Windows Firewall for the ports:

   ```powershell
   New-NetFirewallRule -DisplayName "SSC Frontend"   -Direction Inbound -LocalPort 3000 -Protocol TCP -Action Allow
   New-NetFirewallRule -DisplayName "SSC Main API"   -Direction Inbound -LocalPort 8081 -Protocol TCP -Action Allow
   New-NetFirewallRule -DisplayName "SSC FileServer" -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow
   New-NetFirewallRule -DisplayName "SSC MinIO"      -Direction Inbound -LocalPort 9000 -Protocol TCP -Action Allow
   ```

4. Add the frontend origin to the **Google OAuth client**'s authorized
   JavaScript origins (`http://<SERVER-IP>:3000`) or Google sign-in will
   be rejected.

---

## 7. Start automatically on boot (optional)

Simplest: Task Scheduler.

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
           -Argument "-ExecutionPolicy Bypass -File C:\SSC-System\scripts\start-all.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "SSC-System" -Action $action -Trigger $trigger `
    -RunLevel Highest -User "SYSTEM"
```

(For proper Windows services with restart-on-crash, install each service
with [NSSM](https://nssm.cc/) instead — out of scope here.)

---

## 8. Updating to the latest code

```powershell
cd C:\SSC-System
git pull
git submodule update --init --remote

# rebuild whatever changed:
cd ssc-booking-backend    ; mvn clean package -DskipTests
cd ..\ssc-booking-fileserver ; mvn clean package -DskipTests
cd ..\ssc-booking-frontend   ; npm install ; npm run build
```

Then restart the services (`scripts\stop-all.ps1` + `scripts\start-all.ps1`).
Flyway applies any new database migrations automatically on backend start.

---

## 9. Troubleshooting

| Problem | Fix |
| ------- | --- |
| `Port 8081 was already in use` | Another copy is running — run `scripts\stop-all.ps1`, or find it with `netstat -ano \| findstr :8081` and `taskkill /PID <pid> /F` |
| Backend exits with `Access denied for user 'sscuser'` | Re-run the SQL in step 3.1; confirm with `mysql -u sscuser -psscpassword ssc_booking -e "SELECT 1;"` |
| Backend exits with Flyway `Migration checksum mismatch` | The database was created by a different code version. For a dev/demo DB the simplest fix is `DROP DATABASE ssc_booking;` then re-run step 3.1 and restart the backend (this deletes all data) |
| File server: `MinIO ... Connection refused` | MinIO isn't running — start it first (window 1) |
| Frontend shows "Network error — is the backend running?" | Main API isn't up on 8081, or `NEXT_PUBLIC_API_URL` points at the wrong host (rebuild after editing `.env.local`) |
| Google sign-in rejected | The frontend origin isn't in the OAuth client's authorized JavaScript origins |
| `mvn` / `java` / `node` not recognized | Reopen PowerShell after installing, or add the install folder to PATH |
| Logout / session expires quickly | By design — JWT lifespan is 5 minutes (`app.jwt.expiration` in the backend `application.yml`) |
