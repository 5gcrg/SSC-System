# SSC Event Booking System

Paperless event management for Cor Jesu College, Inc.

## Repositories

| Folder | Stack | Port |
| ------ | ----- | ---- |
| `ssc-booking-frontend/` | Next.js | 3000 |
| `ssc-booking-backend/` | Spring Boot (main API) | 8081 |
| `ssc-booking-fileserver/` | Spring Boot (files → MinIO) | 8080 |

> On this machine the three folders are **directory junctions** pointing at the
> existing repos (`Desktop\SSC v0`, `Desktop\ssc-booking-backend`,
> `C:\Users\User\expert-funicular`). On a fresh clone, `git clone` each app repo
> into its folder instead.

## Quick Start

### 1. Clone
```
git clone https://github.com/yourorg/ssc-system
cd ssc-system
```

### 2. Configure
```
cp .env.example .env
# Edit .env — set real passwords and keys
```

### 3a. Development mode
```
# Infrastructure + file server in Docker
docker compose -f docker-compose.dev.yml up -d

# Run backend locally
cd ssc-booking-backend
mvn spring-boot:run

# Run frontend locally
cd ssc-booking-frontend
npm run dev
```

### 3b. Production / Demo mode
```
# Everything in Docker — one command
docker compose -f docker-compose.prod.yml up -d --build
```

## Services

| Service | URL |
| ------- | --- |
| Frontend | http://localhost:3000 |
| Main API | http://localhost:8081 |
| File Server | http://localhost:8080 |
| MinIO Console | http://localhost:9001 (sscadmin / sscpassword123) |
| MySQL | localhost:3306 |

## Daily commands

```
# View logs
docker compose -f docker-compose.prod.yml logs -f

# View one service
docker compose -f docker-compose.prod.yml logs -f backend

# Stop everything
docker compose -f docker-compose.prod.yml down

# Fresh start (deletes all data)
docker compose -f docker-compose.prod.yml down -v

# Rebuild one service after code changes
docker compose -f docker-compose.prod.yml up -d --build frontend
docker compose -f docker-compose.prod.yml up -d --build backend
docker compose -f docker-compose.prod.yml up -d --build fileserver
```

## Test it's running

```
curl http://localhost:8081/api/v1/ping        → {"status":"UP"}
curl http://localhost:8080/actuator/health    → {"status":"UP"}
open http://localhost:3000/login              → login page loads
```

## Environment Variables

See `.env.example` for all required variables. **Never commit `.env` to git.**

## JWT Secret

`JWT_SECRET` must be identical in both `ssc-booking-backend` and
`ssc-booking-fileserver`. Both services read it from the same `JWT_SECRET`
environment variable.
