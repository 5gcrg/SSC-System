# SSC Booking System — Local Production Setup Guide

> **Branch:** `LocalProd` — School deployment build for CJC Student Services Center.

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Project Structure](#3-project-structure)
4. [Environment Configuration](#4-environment-configuration)
5. [First-Time Setup](#5-first-time-setup)
6. [Starting & Stopping Services](#6-starting--stopping-services)
7. [Accessing the System](#7-accessing-the-system)
8. [Network Access via Cloudflare Tunnel](#8-network-access-via-cloudflare-tunnel)
9. [Google OAuth Configuration](#9-google-oauth-configuration)
10. [Service Monitoring](#10-service-monitoring)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. System Architecture

The SSC System runs four background services on fixed local ports:

| Service            | Technology            | Default Port |
|--------------------|-----------------------|:------------:|
| **Frontend**       | Next.js               | `9003`       |
| **Backend API**    | Spring Boot (Java)    | `9004`       |
| **File Server**    | Spring Boot (Java)    | `9005`       |
| **MinIO Storage**  | MinIO S3-compatible   | `9006`       |
| **MinIO Console**  | MinIO Web UI          | `9007`       |
| **Database**       | MySQL 8               | `3306`       |

All ports are configurable via the root `.env` file.

---

## 2. Prerequisites

Install the following before running the system:

| Tool | Minimum Version | Download |
|------|----------------|---------|
| **Node.js** | 18.x LTS or higher | https://nodejs.org |
| **Java JDK** | 21 | https://adoptium.net |
| **MySQL** | 8.0 | https://dev.mysql.com/downloads/mysql/ |
| **MinIO** | Latest (RELEASE.2024+) | https://min.io/download |
| **PowerShell** | 5.1+ (built into Windows) | — |
| **Git** | Any recent version | https://git-scm.com |

> **Note:** Running `powershell -ExecutionPolicy Bypass -File scripts\SETUP.ps1` will automatically download and configure MinIO and verify all prerequisites.

---

## 3. Project Structure

```
SSC-System/
├── .env                          ← Root environment configuration (edit this)
├── .gitignore
├── README.md                     ← This file
├── scripts/
│   ├── SETUP.ps1                 ← First-time automated setup
│   ├── start-all.ps1             ← Start all 4 services
│   ├── stop-all.ps1              ← Stop all services gracefully
│   ├── monitor.ps1               ← Live service health monitor
│   └── ServiceLib.psm1           ← Shared service management library
├── ssc-booking-frontend/         ← Next.js web application
│   └── .env.local                ← Frontend-specific env (auto-derived from root .env)
├── ssc-booking-backend/          ← Spring Boot main API
└── ssc-booking-fileserver/       ← Spring Boot document/file server
```

---

## 4. Environment Configuration

The single source of truth for all configuration is the root `.env` file.  
**Edit this file before starting any services.**

### Key Variables to Update

```env
# ── Database ─────────────────────────────────────────────────────────────────
MYSQL_ROOT_PASSWORD=rootpassword    # Change for production use
MYSQL_DATABASE=ssc_booking
MYSQL_USER=sscuser
MYSQL_PASSWORD=sscpassword          # Change for production use

# ── MinIO Object Storage ──────────────────────────────────────────────────────
MINIO_PORT=9006
MINIO_CONSOLE_PORT=9007
MINIO_URL=http://localhost:9006
MINIO_PUBLIC_URL=http://localhost:9006

# ── Security ─────────────────────────────────────────────────────────────────
JWT_SECRET=dev-secret-key-change-in-production-must-be-at-least-32-characters-long
# ↑ IMPORTANT: Change this to a strong random string in production

# ── Google OAuth (sign-in with Google) ────────────────────────────────────────
GOOGLE_CLIENT_ID=483440253663-4hlia5o3c85g9q51m8h6afcd09j0vigb.apps.googleusercontent.com

# ── Service Ports ─────────────────────────────────────────────────────────────
FRONTEND_PORT=9003
FRONTEND_URL=http://localhost:9003
BACKEND_PORT=9004
FILESERVER_PORT=9005

# ── CORS (Backend accepts requests from these origins) ─────────────────────────
ALLOWED_ORIGINS=http://localhost:9003,http://localhost:9004

# ── Mail (enable for email notifications) ─────────────────────────────────────
MAIL_HOST=smtp.gmail.com
MAIL_PORT=587
MAIL_USERNAME=your-email@g.cjc.edu.ph
MAIL_PASSWORD=your-gmail-app-password    # Google App Password (not your real password)
MAIL_FROM=your-email@g.cjc.edu.ph
MAIL_ENABLED=false                        # Set to true to enable emails
```

### Frontend-specific `.env.local`

Located at `ssc-booking-frontend/.env.local`. Values are automatically inherited from the root `.env` via the startup scripts. You should not need to edit this file manually.

---

## 5. First-Time Setup

### Step 1: Clone the Repository

```powershell
git clone <repository-url> SSC-System
cd SSC-System
git checkout LocalProd
```

### Step 2: Start MySQL (XAMPP or Windows Service)

1. Start MySQL from the **XAMPP Control Panel** (or start your local MySQL service on port 3306).
2. The setup script will automatically detect the running MySQL service and provision the `ssc_booking` database and `sscuser` account.

### Step 3: Run Automated Setup

This script verifies prerequisites, checks that MySQL is actively running on port 3306, provisions the database, downloads MinIO automatically (handling 302 redirects), and builds all application services:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\SETUP.ps1
```

### Step 4: Configure `.env`

Edit the root `.env` file and update:
- Database credentials
- `JWT_SECRET` (use a strong random string)
- Mail settings if email notifications are needed

### Step 5: Install Frontend Dependencies

```powershell
cd ssc-booking-frontend
npm install
cd ..
```

---

## 6. Starting & Stopping Services

### Start All Services

Launches MinIO, File Server, Backend API, and Next.js Frontend as background processes:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1
```

### Stop All Services

Gracefully stops all running services:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\stop-all.ps1
```

### Monitor Services (Live Dashboard)

Shows real-time health status for all 4 services:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\monitor.ps1
```

---

## 7. Accessing the System

Once all services are running:

| Interface | URL |
|-----------|-----|
| **SSC Web Application** | http://localhost:9003 |
| **Backend API (Swagger)** | http://localhost:9004/swagger-ui.html |
| **MinIO Console** | http://localhost:9007 |

**Default admin login credentials** are set via Google OAuth — sign in with your CJC Google account (`@g.cjc.edu.ph`).

---

## 8. Network Access via Cloudflare Tunnel

To allow other devices on the school network (or over the internet) to access the system without port forwarding:

### Start a Cloudflare Tunnel

```powershell
npx -y cloudflared tunnel --url http://localhost:9003
```

This generates a public HTTPS URL such as:
```
https://xxxx-xxxx.trycloudflare.com
```

### Update `.env` with the Cloudflare URL

Edit the root `.env`:

```env
# Update FRONTEND_URL to the Cloudflare public URL
FRONTEND_URL=https://xxxx-xxxx.trycloudflare.com

# Add the Cloudflare URL to ALLOWED_ORIGINS for CORS
ALLOWED_ORIGINS=http://localhost:9003,http://localhost:9004,https://xxxx-xxxx.trycloudflare.com
```

Then **restart services** for changes to take effect.

---

## 9. Google OAuth Configuration

For Google Sign-In to work, the public URL must be registered in Google Cloud Console.

### Steps

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Navigate to **APIs & Services → Credentials**
3. Select your **OAuth 2.0 Client ID**
4. Under **Authorized JavaScript origins**, add:
   ```
   http://localhost:9003
   https://xxxx-xxxx.trycloudflare.com   ← add your Cloudflare URL here
   ```
5. Under **Authorized redirect URIs**, add the same URLs
6. Click **Save**

> Changes in Google Console can take a few minutes to propagate.

---

## 10. Service Monitoring

The `monitor.ps1` script provides a live view of all service health:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\monitor.ps1
```

It checks:
- ✅ Whether each service is running (by process and port)
- ✅ HTTP health endpoint responses
- ✅ Memory usage of Java processes

Logs for each service are written to the `logs/` directory:
```
logs/
├── frontend.log
├── backend.log
├── fileserver.log
└── minio.log
```

---

## 11. Troubleshooting

### Service Won't Start

1. Check `logs/<service>.log` for error output.
2. Ensure the port is not already in use:
   ```powershell
   netstat -ano | findstr :9003
   netstat -ano | findstr :9004
   ```
3. Run `scripts\stop-all.ps1` and restart.

### Database Connection Refused

- Verify MySQL is running: `Get-Service -Name MySQL*`
- Confirm `MYSQL_USER`, `MYSQL_PASSWORD`, and `MYSQL_DATABASE` in `.env` match your MySQL setup.

### Google OAuth Error (`redirect_uri_mismatch`)

- The URL you're accessing from must match exactly what's registered in Google Cloud Console (see [Section 9](#9-google-oauth-configuration)).

### Files Not Loading / Upload Fails

- MinIO must be running and accessible at port `9006`.
- Check `logs/minio.log` and `logs/fileserver.log`.

### Frontend Shows Blank Page or API Errors

- Confirm `NEXT_PUBLIC_API_URL` in `.env` points to the correct backend host.
- If accessing via Cloudflare URL, ensure `ALLOWED_ORIGINS` includes that URL in `.env`.

---

## Port Reference

| Port | Service |
|------|---------|
| `9003` | Next.js Frontend |
| `9004` | Spring Boot Backend API |
| `9005` | Spring Boot File Server |
| `9006` | MinIO S3 Storage |
| `9007` | MinIO Admin Console |
| `3306` | MySQL Database |
