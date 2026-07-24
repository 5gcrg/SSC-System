# Wiping All Submission Data (Local Dev)

Resets every submission-related table in the local `ssc_booking` MySQL database, including
notifications and audit logs, and optionally the uploaded files in MinIO. Reference data —
users, students, masterlist, organizations, departments, courses, templates, checklists,
settings — is **not** touched.

> **Warning:** This permanently deletes all proposals, documents, reviews, approval slips,
> activity reports, notifications, and audit logs. Local/dev use only.

## What gets wiped

| Table | Contents |
|---|---|
| `submissions` | Event proposals |
| `documents` | Documents attached to proposals |
| `document_versions` | Every uploaded file version |
| `moderator_assignments` | Moderator ↔ document assignments |
| `reviews` | Moderator decisions & escalations |
| `admin_reviews` | Admin final reviews |
| `approval_slips` | Generated approval slips |
| `activity_reports` | Post-event activity reports |
| `notifications` | All user notifications (would contain dangling references) |
| `audit_logs` | All audit history (would contain dangling references) |

## Step 1 — (Recommended) Stop the backend

Avoids in-flight writes landing mid-wipe. From the repo root:

```powershell
Import-Module .\scripts\ServiceLib.psm1
Stop-SscService backend
```

## Step 2 — Run the wipe

```powershell
mysql -u sscuser -psscpassword ssc_booking -e "SET FOREIGN_KEY_CHECKS=0; TRUNCATE TABLE reviews; TRUNCATE TABLE moderator_assignments; TRUNCATE TABLE document_versions; TRUNCATE TABLE documents; TRUNCATE TABLE admin_reviews; TRUNCATE TABLE approval_slips; TRUNCATE TABLE activity_reports; TRUNCATE TABLE submissions; TRUNCATE TABLE notifications; TRUNCATE TABLE audit_logs; SET FOREIGN_KEY_CHECKS=1;"
```

`FOREIGN_KEY_CHECKS=0` lets the truncates run in any order; it is re-enabled at the end of
the same session and never affects other connections.

## Step 3 — (Optional) Delete the uploaded files in MinIO

The database wipe does not remove the PDFs already stored in MinIO. They are harmless
orphans, but to reclaim the space:

```powershell
Stop-SscService minio
Remove-Item -Recurse -Force .tools\minio-data\ssc-documents\submissions
Start-SscService minio
```

## Step 4 — Restart the backend

```powershell
Start-SscService backend
```

## Step 5 — Verify

```powershell
mysql -u sscuser -psscpassword ssc_booking -e "SELECT COUNT(*) AS submissions FROM submissions; SELECT COUNT(*) AS documents FROM documents; SELECT COUNT(*) AS notifications FROM notifications;"
```

All counts should be `0`. Log in as a student and confirm the submissions list is empty,
then create a fresh proposal to confirm the flow still works end-to-end.
