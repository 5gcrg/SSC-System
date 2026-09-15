# SSC Endorser and Final Approval Workflow

## Status

Implemented on the `LocalProd` branch on September 15, 2026. The database changes are delivered by Flyway migrations `V62`–`V64` and are included in `scripts/SETUP.ps1` validation.

## Objective

Introduce a clear three-level document review process:

```text
Moderator review
      ↓ Noted
SSC Endorser review
      ↓ Noted
SSC Admin review
      ↓ Final approval
Approved proposal
```

The current `SSC_ADMIN` role becomes `SSC_ENDORSER`. A new, restricted `SSC_ADMIN` role performs final approval only after every required document has been noted by both the Moderator and SSC Endorser.

The Academic School Year settings currently owned by `SSC_SYSTEM_ADMIN` move to `SSC_ENDORSER`.

## Final terminology

| Current term | New term | Scope |
|---|---|---|
| SSC Admin | SSC Endorser | All existing SSC Admin accounts and operational responsibilities |
| Moderator Approve | Moderator Note | Moderator document review only |
| Moderator Approved | Moderator Noted | Moderator document status and history |
| SSC Admin Approve | SSC Endorser Note | Endorser document review only |
| SSC Admin Approved | SSC Endorser Noted | Endorser document status and history |
| New SSC Admin Approve | Final Approve | Final decision on the complete noted package |
| Pending Admin Review | Awaiting SSC Endorser | First administrative review stage |
| Ready for Final Approval | Awaiting SSC Admin | Final approval stage |

Do not perform a global replacement of `Approved` with `Noted`. `Approved` remains the correct term for the final SSC Admin decision and for historical records created before this workflow.

## Role definitions

### Moderator

- Reviews only documents assigned to the Moderator.
- Can select `Note` or `Return for Revision`.
- Must enter the current approval PIN for either action.
- Cannot endorse or finally approve a proposal.

### SSC Endorser

- Replaces the current SSC Admin role and label.
- Retains the current operational administration features, including event management, masterlists, students, faculty, organizations, document requirements, templates, categories, communications, and operational reports.
- Reviews documents after the Moderator stage is complete.
- Can select `Note` or `Return for Revision`.
- Must enter the current approval PIN for either action.
- Owns the Academic School Year settings.
- Cannot issue final approval.

### SSC Admin

- New restricted role.
- Sees only the final-approval dashboard, final-approval queue, decision history, notifications, and PIN/profile settings.
- Can open and inspect documents already noted by the SSC Endorser.
- Can approve the complete document package in one transaction.
- Must enter the current approval PIN before final approval.
- Cannot modify masterlists, organizations, templates, requirements, academic-year settings, technical settings, roles, or user records.
- May return a package to the SSC Endorser with required remarks when final approval cannot be granted.

### SSC System Admin

- Remains responsible for technical and security administration.
- Manages roles, SMTP, email templates, backups, retention, file limits, session/security configuration, and audit access.
- May view the current Academic School Year for support and audit purposes but cannot change it.
- Does not participate in routine document notation or final approval.

## Permission matrix

| Capability | Moderator | SSC Endorser | SSC Admin | System Admin |
|---|---:|---:|---:|---:|
| Review assigned documents | Yes | No | No | No |
| Note after Moderator review | No | Yes | No | No |
| Final approve a noted package | No | No | Yes | No |
| Return document to student | Yes | Yes | No | No |
| Return package to Endorser | No | No | Yes | No |
| Manage operational records | No | Yes | No | No |
| Change Academic School Year | No | Yes | No | No |
| View Academic School Year | Yes | Yes | Yes | Yes |
| Manage technical settings | No | No | No | Yes |
| Manage roles | No | No | No | Yes |

Backend authorization is the source of truth. Frontend visibility must mirror the backend but must never be the only security control.

## Workflow states

### Submission states

Add `ENDORSER_REVIEW` and retain `ADMIN_REVIEW` for the new final SSC Admin stage.

```text
DRAFT
→ PENDING
→ MODERATOR_REVIEW
→ ENDORSER_REVIEW
→ ADMIN_REVIEW
→ APPROVED
```

`REJECTED` remains available for legacy and explicitly terminal cases. Normal correction handling should use a return transition instead of creating a terminal rejection.

### Document states

The aggregate document status should support:

- `PENDING`
- `UNDER_REVIEW`
- `MODERATOR_NOTED`
- `ENDORSER_NOTED`
- `APPROVED`
- `REVISION_REQUIRED`
- `REJECTED` for legacy compatibility

The displayed status must always identify the stage. A generic `Noted` badge is insufficient when two different roles note the same document.

### Allowed transitions

| Current state | Actor | Action | Result |
|---|---|---|---|
| `PENDING` or `UNDER_REVIEW` | Moderator | Note | `MODERATOR_NOTED` |
| `PENDING` or `UNDER_REVIEW` | Moderator | Return for Revision | `REVISION_REQUIRED` |
| `MODERATOR_NOTED` | SSC Endorser | Note | `ENDORSER_NOTED` |
| `MODERATOR_NOTED` | SSC Endorser | Return for Revision | `REVISION_REQUIRED` |
| All required documents `ENDORSER_NOTED` | System | Advance | Submission becomes `ADMIN_REVIEW` |
| Complete noted package | SSC Admin | Final Approve | All current required documents become `APPROVED`; submission becomes `APPROVED` |
| Complete noted package | SSC Admin | Return to Endorser | Submission becomes `ENDORSER_REVIEW`; affected documents return to `MODERATOR_NOTED` |

## Decision history and document versions

Create an append-only `document_stage_decisions` table. Do not depend only on the mutable `documents.status` field for audit history.

Recommended columns:

| Column | Purpose |
|---|---|
| `decision_id` | UUID primary key |
| `submission_id` | Indexed parent submission |
| `document_id` | Indexed document |
| `document_version_id` | Exact file version reviewed |
| `stage` | `MODERATOR`, `ENDORSER`, or `FINAL_ADMIN` |
| `decision` | `NOTED`, `RETURNED`, or `APPROVED` |
| `actor_id` | User who performed the action |
| `actor_role` | Role at the time of the action |
| `remarks` | Required for return actions |
| `decided_at` | Server timestamp |

Recommended indexes:

- `(submission_id, stage, decided_at)`
- `(document_id, document_version_id, stage, decided_at)`
- `(actor_id, decided_at)`

Every decision must reference the exact document version that was reviewed. When a student uploads a replacement version:

1. Preserve the old decisions for audit history.
2. Mark them as superseded through version comparison rather than deleting them.
3. Reset the current document to the appropriate review stage.
4. Require the Moderator and SSC Endorser to note the new version again.
5. Remove the proposal from the SSC Admin final-approval queue until all current versions are noted.

## Final approval transaction

The SSC Admin action must operate on the entire required package, not one document at a time.

Before final approval, the backend must lock the submission and validate that:

- The submission is currently `ADMIN_REVIEW`.
- Every required checklist document exists.
- Every required document has an uploaded current version.
- The current version of every required document has an `ENDORSER/NOTED` decision.
- No current document is `REVISION_REQUIRED` or `REJECTED`.
- No document was replaced after the Endorser notation.
- No final approval already exists.
- The actor has the `SSC_ADMIN` role.
- The submitted PIN matches the actor's current server-side PIN hash.

If every validation passes, one transaction must:

1. Add a `FINAL_ADMIN/APPROVED` decision for every current required document.
2. Change every current required document to `APPROVED`.
3. Create the final submission approval record.
4. Change the submission to `APPROVED`.
5. Create or activate the approval-slip workflow.
6. Write audit entries.
7. Queue notifications.

Any failure must roll back the complete transaction.

## Return behavior

### Moderator return

- Label: `Return for Revision`
- Destination: student/applicant
- Remarks: required
- Result: document becomes `REVISION_REQUIRED`

### SSC Endorser return

- Label: `Return for Revision`
- Destination: student/applicant, with Moderator visibility
- Remarks: required
- Result: document becomes `REVISION_REQUIRED`

### SSC Admin return

- Label: `Return to SSC Endorser`
- Destination: SSC Endorser
- Remarks: required
- Result: submission returns to `ENDORSER_REVIEW`
- The final Admin does not edit or note documents.

This return capability prevents a proposal from becoming permanently stuck when the final approver identifies an issue. It does not grant the SSC Admin operational editing permissions.

## Approval PIN requirements

The existing server-managed BCrypt PIN remains the only source of truth.

Update PIN eligibility to include:

- `MODERATOR`
- `SSC_ENDORSER`
- `SSC_ADMIN`

Remove `SSC_SYSTEM_ADMIN` from ordinary decision authorization unless a separately documented emergency override is approved by stakeholders.

PIN rules:

- Require the actor's current PIN for Note, Return, Final Approve, and Return to Endorser.
- Verify the PIN on the backend immediately before acquiring or completing the decision transaction.
- Never store the PIN in browser storage, logs, audit metadata, or decision records.
- A changed PIN must take effect on the next request without requiring logout.
- Existing PIN hashes remain attached to users when `SSC_ADMIN` accounts migrate to `SSC_ENDORSER`.

## Academic School Year ownership

Move edit ownership of these existing settings to `SSC_ENDORSER`:

- `semester_label`
- `semester_start_date`
- `semester_end_date`

Use the UI title `Academic Year and Term` while retaining the existing database keys for compatibility.

Recommended backend approach:

1. Add an `owner_role` column to `system_settings`, or implement an equivalent server-side key policy.
2. Set the three academic keys to `SSC_ENDORSER`.
3. Set technical keys to `SSC_SYSTEM_ADMIN`.
4. Permit authenticated roles to read the current academic period where required.
5. Permit updates only when the current user's role matches the setting owner.

The SSC Endorser receives a dedicated `Academic Year and Term` page or settings card. Do not expose the complete technical System Settings page to the Endorser.

System Admin may retain read-only visibility of the academic period but must receive `403 Forbidden` when attempting to update it.

## Backend implementation

### Role and security changes

Update at minimum:

- `UserRole`
- `SecurityUtils`
- `ApprovalPinService`
- Authentication/session role serialization
- `UserService.changeUserRole`
- All controller `@PreAuthorize` expressions
- Notification recipient selection
- User, student, faculty, and Moderator filtering that currently treats `SSC_ADMIN` specially

Avoid broad helpers such as `isAdmin()` when the permissions differ. Introduce explicit checks such as:

- `isOperationalAdmin()` for `SSC_ENDORSER`
- `isFinalApprover()` for `SSC_ADMIN`
- `isSystemAdmin()` for `SSC_SYSTEM_ADMIN`

### API separation

Recommended endpoints:

```text
POST /api/v1/moderator/assignments/{assignmentId}/note
POST /api/v1/moderator/assignments/{assignmentId}/return

GET  /api/v1/endorser/submissions
POST /api/v1/endorser/documents/{documentId}/note
POST /api/v1/endorser/documents/{documentId}/return

GET  /api/v1/ssc-admin/final-approvals
GET  /api/v1/ssc-admin/final-approvals/{submissionId}
POST /api/v1/ssc-admin/final-approvals/{submissionId}/approve
POST /api/v1/ssc-admin/final-approvals/{submissionId}/return
```

Use exact-role authorization on the mutation endpoints.

Do not keep one shared controller whose class-level rule allows both Endorser and final Admin to invoke every method.

### Service separation

Split the current administrative review logic into:

- `EndorserReviewService`
- `FinalApprovalService`
- A shared read-only workflow/query service where appropriate

The final approval service must not contain masterlist, reassignment, template, or other operational behavior.

### Notification events

Add or rename events for:

- `READY_FOR_ENDORSER_REVIEW`
- `DOCUMENT_NOTED_BY_MODERATOR`
- `DOCUMENT_RETURNED_BY_MODERATOR`
- `DOCUMENT_NOTED_BY_ENDORSER`
- `DOCUMENT_RETURNED_BY_ENDORSER`
- `READY_FOR_FINAL_APPROVAL`
- `FINAL_APPROVAL_GRANTED`
- `FINAL_APPROVAL_RETURNED`

Notification text must name the role and stage clearly.

### Audit actions

Add explicit audit action types:

- `MODERATOR_DOCUMENT_NOTED`
- `MODERATOR_DOCUMENT_RETURNED`
- `ENDORSER_DOCUMENT_NOTED`
- `ENDORSER_DOCUMENT_RETURNED`
- `FINAL_APPROVAL_GRANTED`
- `FINAL_APPROVAL_RETURNED`
- `ACADEMIC_YEAR_CHANGED`

Store IDs and non-sensitive metadata only. Never include the approval PIN.

## Frontend implementation

### Shared role definitions

Add `SSC_ENDORSER` everywhere roles are defined or resolved:

- Authentication API types
- Auth context types
- Role labels
- Dashboard routing
- Page guards
- Sidebar role logic
- Role-management controls
- Header and profile labels
- Mock/test data

### SSC Endorser interface

Reuse the existing operational Admin pages where practical to minimize route churn, but present the role as `SSC Endorser` throughout the interface.

Changes include:

- Replace Endorser-stage `Approve` buttons with `Note`.
- Replace Endorser-stage `Approved` badges with `Endorser Noted`.
- Add `Academic Year and Term` to the Endorser navigation.
- Remove technical System Settings, SMTP, email-template, backup, and role-management access.
- Show an Endorser queue containing only proposals ready for that stage.

### SSC Admin interface

Create a focused interface containing:

- Dashboard summary
- Awaiting Final Approval queue
- Final approval detail page
- Decision history
- Notifications
- PIN/profile settings

Do not display masterlist, organizations, templates, requirements, reports configuration, communications management, or system-management navigation.

The primary decision button should read `Final Approve All Documents` and show the number of current required documents covered by the action.

### Status presentation

Use explicit stage labels:

- `Awaiting Moderator`
- `Moderator Noted`
- `Awaiting SSC Endorser`
- `SSC Endorser Noted`
- `Awaiting SSC Admin`
- `Finally Approved`
- `Revision Required`

Update student timelines, dashboards, submission lists, notifications, approval slips, exports, analytics, and email templates where the current SSC Admin terminology appears.

## Role migration and account provisioning

### Existing accounts

All active and inactive users whose role is currently `SSC_ADMIN` must migrate to `SSC_ENDORSER`.

The migration must preserve:

- User ID
- Email and profile information
- Active/inactive status
- Approval PIN hash and PIN-change timestamp
- Audit relationships
- Existing review relationships

### New SSC Admin account

Do not automatically choose an arbitrary existing user as the new final SSC Admin.

Before enabling the workflow, stakeholders must nominate the first final SSC Admin account. System Admin should then assign the role using Role Management.

Recommended safeguards:

- Require at least one active `SSC_ADMIN` before enabling the new workflow.
- Prevent deactivation or demotion of the last active `SSC_ADMIN`.
- Prevent deactivation or demotion of the last active `SSC_SYSTEM_ADMIN`.
- Record every role change in the audit log.
- Refresh or invalidate the changed user's active session so the new permissions take effect immediately.

## Database migrations

Use new forward-only Flyway migrations. Do not edit V1 through V61.

Recommended migration sequence:

### V62: Introduce SSC Endorser role

- Update existing `SSC_ADMIN` users to `SSC_ENDORSER`.
- Preserve user IDs and PIN data.
- Add any required role-related indexes or constraints.

The `users.role` column is currently a string, so no database enum alteration is required. Application enums and validation must still be updated before the migrated role is read.

### V63: Add staged workflow decisions

- Create `document_stage_decisions`.
- Add the new document and submission status values at the application level.
- Add indexes used by stage queues and current-version validation.
- Move unfinished legacy `ADMIN_REVIEW` submissions to `ENDORSER_REVIEW`.
- Leave already approved historical submissions unchanged.

### V64: Assign settings ownership

- Add setting ownership metadata if using the data-driven policy.
- Assign academic period keys to `SSC_ENDORSER`.
- Assign technical keys to `SSC_SYSTEM_ADMIN`.

Historical `APPROVED` records must remain historical approvals. Do not relabel them as `NOTED`.

## Setup script changes

Update `scripts/SETUP.ps1` to verify that:

- V62 through V64 are present.
- At least one SSC Endorser account exists after migration.
- The deployment has an explicit method to appoint the first new SSC Admin.
- Academic settings have the correct owner.

Recommended setup option:

```powershell
scripts\SETUP.ps1 -SscAdminEmail "final.approver@g.cjc.edu.ph"
```

If the supplied email is not yet a user, create a pending/invited account rather than silently skipping final-approver setup. If the option is omitted, setup should finish with a prominent warning and instructions; the application must not move proposals into a queue with no eligible approver.

## Backward compatibility

- Keep completed historical approvals readable and printable.
- Preserve existing approval-slip records and reference numbers.
- Treat old `APPROVED` Moderator and Admin review rows as legacy decisions in history views.
- Use new stage-specific decisions only for actions after the workflow cutover.
- Update API clients together with backend status additions to prevent unknown-status rendering.
- Do not delete or rewrite old audit events.

## Testing requirements

### Migration tests

- Clean installation applies V1 through the new latest migration.
- Upgrade from V61 succeeds without data loss.
- Existing `SSC_ADMIN` users become `SSC_ENDORSER`.
- Existing approval PIN hashes still validate.
- Completed approved proposals remain approved.
- In-progress administrative reviews move to the Endorser stage.
- Academic settings are owned by SSC Endorser.

### Authorization tests

- Moderator cannot access Endorser or final Admin mutations.
- SSC Endorser can note but cannot finally approve.
- SSC Admin can finally approve but cannot modify operational records.
- SSC System Admin cannot note, finally approve, or modify the Academic School Year.
- SSC Endorser cannot modify technical settings.
- Direct API requests receive `403 Forbidden` even if frontend controls are bypassed.

### Workflow tests

- Moderator notation advances the correct document.
- All current documents must be Moderator-noted before Endorser completion.
- Endorser notation advances the correct document.
- All current documents must be Endorser-noted before the SSC Admin queue includes the proposal.
- SSC Admin approval updates all required documents and the submission atomically.
- A failed document validation rolls back the complete final approval.
- Return actions require remarks and restore the correct stage.
- Replacement uploads invalidate previous notation for the replaced version.
- Duplicate and concurrent decisions do not create conflicting active states.

### PIN tests

- Incorrect PIN blocks Moderator notation.
- Incorrect PIN blocks Endorser notation.
- Incorrect PIN blocks final approval.
- Changed PIN works immediately for the next decision.
- Previous PIN stops working immediately.
- No PIN value appears in logs, audit metadata, API responses, or stored frontend state.

### Frontend tests

- Every role lands on the correct dashboard.
- Navigation contains only authorized features.
- Moderator and Endorser actions display `Note`, not `Approve`.
- SSC Admin sees only eligible fully noted proposals.
- Academic-year editing appears only for SSC Endorser.
- Student timelines show both notation stages and final approval.
- Role changes take effect after session refresh or forced reauthentication.

## Implementation sequence

1. Confirm and record the first new SSC Admin account.
2. Add `SSC_ENDORSER` to backend and frontend role definitions.
3. Add forward-only role and workflow migrations.
4. Implement the staged decision model and version validation.
5. Change Moderator approval actions to notation actions.
6. Convert the current SSC Admin workflow and UI into SSC Endorser behavior.
7. Add the restricted SSC Admin final-approval service and interface.
8. Transfer Academic School Year update ownership to SSC Endorser.
9. Update notifications, audit events, timelines, exports, slips, and email text.
10. Update `SETUP.ps1` and deployment documentation.
11. Run backend, frontend, migration, concurrency, and clean-install tests.
12. Conduct stakeholder user-acceptance testing with all four staff roles.

## Acceptance criteria

The implementation is complete only when all of the following are true:

- Existing SSC Admin users appear as SSC Endorsers without losing account or PIN data.
- Moderator actions and history use `Noted` terminology.
- SSC Endorser actions and history use `Noted` terminology.
- The SSC Admin queue contains only proposals whose current required document versions are Endorser-noted.
- One successful SSC Admin action finally approves the complete package atomically.
- SSC Admin has no operational or technical management permissions.
- SSC Endorser, not System Admin, can update Academic School Year settings.
- System Admin receives a backend authorization error when attempting to update academic-period keys.
- Reuploaded documents cannot retain stale Moderator or Endorser notation.
- All decisions identify actor, role, stage, document version, remarks, and timestamp.
- PIN changes take effect immediately and old PINs cannot authorize decisions.
- Clean setup and V61 upgrade paths both succeed.
- Automated tests and stakeholder acceptance scenarios pass.

## Recommended stakeholder validation scenario

Use one test proposal containing several required documents:

1. A student submits the proposal.
2. The Moderator notes every assigned current document version.
3. Confirm the proposal appears in the SSC Endorser queue.
4. The SSC Endorser notes every document.
5. Confirm the proposal disappears from the Endorser queue and appears in the SSC Admin queue.
6. Replace one document and confirm the proposal is removed from the final queue.
7. Repeat the required Moderator and Endorser notation for the new version.
8. Change the SSC Admin PIN and verify the old PIN fails immediately.
9. Final approve the complete package with the new PIN.
10. Confirm all documents and the proposal are approved, the approval slip is available, notifications were sent, and the full audit trail is visible.
