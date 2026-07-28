# SSC Event Booking System — IT Setup & Deployment Guide

This guide is for IT administrators setting up and maintaining the SSC Event Booking System on a Windows Server environment (or Windows 10/11 for local staging).

---

## 1. System Architecture

The application runs as five interconnected components:

| Service | Component / Folder | Port | Technology | Dependencies |
| :--- | :--- | :--- | :--- | :--- |
| **Database** | MySQL Server | `3306` | MySQL 8.0 | — |
| **Object Storage** | `minio\` | `9000` (API)<br>`9001` (Console) | MinIO | — |
| **File Server** | `ssc-booking-fileserver\` | `8080` | Spring Boot (Java 21) | MinIO |
| **Main API** | `ssc-booking-backend\` | `8081` | Spring Boot (Java 21) | MySQL, File Server |
| **Frontend UI** | `ssc-booking-frontend\` | `3000` | Next.js (Node 22) | Main API, File Server |

> **Startup Sequence:** MySQL → MinIO → File Server → Main API → Frontend

---

## 2. Prerequisites

Ensure the following software packages are installed on the server:

* **Git** (2.40+)
* **Java JDK 21** (LTS, Eclipse Temurin recommended)
* **Apache Maven** (3.9.x)
* **Node.js** (22 LTS)
* **MySQL Server** (8.0.x)

### Automated Installation via PowerShell (Elevated)

You can install all prerequisites using `winget`:
```powershell
winget install --id Git.Git -e
winget install --id EclipseAdoptium.Temurin.21.JDK -e
winget install --id Apache.Maven -e
winget install --id OpenJS.NodeJS.LTS -e
winget install --id Oracle.MySQL -e
```
*Note: Restart your PowerShell session after installation to refresh the environment variables.*

---

## 3. One-Time System Setup

1. **Clone Repository with Submodules (`prod` branch):**
   ```powershell
   git clone --recursive -b prod https://github.com/5gcrg/SSC-System.git
   cd SSC-System
   ```
   `prod` is the branch reserved for real deployment; `test/railway-deployment` is Railway's
   test-only branch and should not be used for a production install.

2. **Run the Automated Setup Script:**
   The [setup.ps1](file:///c:/Users/admir/Desktop/SSC-System/scripts/setup.ps1) script handles prerequisite validation, database/user creation, MinIO binary downloading, Maven building, and Next.js frontend compiling:
   
   * **Interactive (asks for MySQL root password):**
     ```powershell
     powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
     ```
   * **Unattended (CI/CD or automated setups):**
     ```powershell
     powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -MySqlRootPassword "your_mysql_root_password"
     ```
     *(Use `""` if MySQL root has no password).*

---

## 4. Production Deployment (Windows Services)

For a stable production environment, run the services in the background as Windows Services. This ensures they start automatically on boot, sequence dependencies correctly, and restart on crash.

### Install Services
Open an **Elevated PowerShell** (Run as Administrator) and execute:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-services.ps1
```
* **How it works:** This script downloads `nssm.exe` (Non-Sucking Service Manager) into `nssm\`, registers four Windows Services (`SSC-MinIO`, `SSC-FileServer`, `SSC-Backend`, `SSC-Frontend`), and configures service dependencies.
* **Logs:** Outputs are routed to:
  * `logs\ssc-minio.log` & `logs\ssc-minio.err.log`
  * `logs\ssc-fileserver.log` & `logs\ssc-fileserver.err.log`
  * `logs\ssc-backend.log` & `logs\ssc-backend.err.log`
  * `logs\ssc-frontend.log` & `logs\ssc-frontend.err.log`

### Uninstall Services
To remove the Windows Services, run (elevated):
```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall-services.ps1
```

---

## 5. Development & Diagnostics

For debugging, local staging, or active development, you can start the services manually in console mode:

* **Start all services:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1
  ```
  This starts the services in the background and launches a live terminal-based monitor board.
* **Monitor services:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\monitor.ps1
  ```
* **Stop all services:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\stop-all.ps1
  ```

---

## 6. Accessing the System from LAN / Network

By default, the application is configured for `localhost` connections. To make it accessible from other devices on the LAN:

1. **Configure Environment Variables:**
   Edit the file [ssc-booking-frontend\.env.local](file:///c:/Users/admir/Desktop/SSC-System/ssc-booking-frontend/.env.local) and replace `localhost` with the server's LAN IP address:
   ```env
   NEXT_PUBLIC_API_URL=http://<SERVER-IP>:8081
   NEXT_PUBLIC_FILESERVER_URL=http://<SERVER-IP>:8080
   ```
   *Note: Next.js injects environment variables at build-time. You must rebuild the frontend using `npm run build` after modifying this file.*

2. **Update CORS Origins:**
   Modify the YAML configuration files to allow connections from the frontend on `<SERVER-IP>:3000`:
   * [ssc-booking-backend\src\main\resources\application.yml](file:///c:/Users/admir/Desktop/SSC-System/ssc-booking-backend/src/main/resources/application.yml) → Add `http://<SERVER-IP>:3000` to `app.cors.allowed-origins`.
   * [ssc-booking-fileserver\src\main\resources\application.yml](file:///c:/Users/admir/Desktop/SSC-System/ssc-booking-fileserver/src/main/resources/application.yml) → Add `http://<SERVER-IP>:3000` to `app.cors.allowed-origins`.

3. **Open Firewall Rules (Elevated):**
   ```powershell
   New-NetFirewallRule -DisplayName "SSC Frontend"   -Direction Inbound -LocalPort 3000 -Protocol TCP -Action Allow
   New-NetFirewallRule -DisplayName "SSC Main API"   -Direction Inbound -LocalPort 8081 -Protocol TCP -Action Allow
   New-NetFirewallRule -DisplayName "SSC FileServer" -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow
   New-NetFirewallRule -DisplayName "SSC MinIO"      -Direction Inbound -LocalPort 9000 -Protocol TCP -Action Allow
   ```

---

## 7. Troubleshooting

| Symptom | Probable Cause | Action |
| :--- | :--- | :--- |
| `Port 8081 was already in use` | Duplicate backend process running | Run `scripts\stop-all.ps1` or run `netstat -ano \| findstr :8081` and kill the PID. |
| `Access denied for user 'sscuser'` | MySQL credentials mismatch | Re-run SQL commands manually or verify password config in `application.yml`. |
| `Migration checksum mismatch` | Database schema out-of-sync | Drop the database: `DROP DATABASE ssc_booking;`, recreate it, and restart the backend. Flyway will automatically run all migrations from scratch. |
| `MinIO Connection refused` | MinIO server is offline | Verify MinIO service state or review `logs\ssc-minio.log`. |
| `Network error` in frontend | Backend is unreachable | Verify `NEXT_PUBLIC_API_URL` in `.env.local` points to the correct address and matches CORS configurations. |
