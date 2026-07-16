# Moderator Proposal Bypassing Moderator Review — Implementation Plan

This plan updates the proposal submission flow so that when a Moderator creates and submits an activity proposal, it bypasses the **Pending Moderator Review** stage (`PENDING`) and transitions directly to **Pending SSC Admin Review** (`ADMIN_REVIEW`).

---

## 1 · Current Proposal Submission Flow
- **Student Flow**:
  1. Proposal created in `DRAFT` status.
  2. Student submits proposal → Submission status is set to `PENDING` (Pending Moderator Review).
  3. Individual uploaded `Document` records are created in `PENDING` status.
  4. Assigned moderators receive notifications.
  5. Once all assigned moderators approve, the proposal transitions to `ADMIN_REVIEW`.
- **Moderator Flow**: Currently, when a moderator submits a proposal, it follows the exact same student flow (entering the `PENDING` stage and requiring moderator review).

---

## 2 · Proposed Solution
- **Workflow Bypassing for Moderators**:
  - In `SubmissionService.submitProposal()`, check the submitter's role.
  - If the submitter is a **Moderator**:
    1. Set the submitted proposal status directly to `SubmissionStatus.ADMIN_REVIEW`.
    2. Set all uploaded `Document` record statuses directly to `DocumentStatus.APPROVED`.
    3. Do **not** send moderator assignment email/in-app notifications (since the documents are already approved).
    4. Automatically trigger the SSC Admin submission notification: `notificationService.notifyAdminsSubmissionReady(submission)`.
    5. Log the audit status change to `ADMIN_REVIEW`.
  - In `SubmissionService.getTimeline()`:
    - If the proposal was created by a **Moderator**:
      - Bypass and exclude the `MODERATOR_REVIEW` timeline event entirely, rendering:
        - `Draft Created` -> completed
        - `Proposal Submitted` -> completed
        - `Under SSC Admin Review` -> current
  - If the submitter is a **Student**, follow the existing workflow without any modifications.

---

## 3 · Proposed Changes

### [Component Name] Backend Submission Logic

#### [MODIFY] [SubmissionService.java](file:///c:/Users/admir/Desktop/SSC-System/ssc-booking-backend/src/main/java/com/cjc/ssc/booking/service/SubmissionService.java)
- In `submitProposal()`: Check if submitter is a moderator; conditionally set proposal status to `ADMIN_REVIEW`, document status to `APPROVED`, skip moderator assignment notifications, and trigger SSC Admin submission notification.
- In `getTimeline()`: Conditionally exclude the moderator review timeline block if the submission creator is a moderator.

---

## 4 · Verification Plan

### Automated Tests
- Run `mvn compile` and `mvn test` on the backend to ensure build compiles and all tests pass.

### Manual Verification
1. Log in as a **Moderator** and create a draft proposal.
2. Complete the document checklist and assign moderators.
3. Submit the proposal.
4. Verify the proposal enters status `Pending SSC Admin Review` (`ADMIN_REVIEW`) immediately.
5. Log in as an **Admin** and verify the proposal appears in the Admin review list, and all document statuses show as approved by the moderator.
6. Verify student proposals still enter `Pending Moderator Review` and function exactly as before.
