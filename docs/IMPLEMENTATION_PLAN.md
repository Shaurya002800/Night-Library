# Night Library: understanding and implementation plan

## Idea and boundaries
The paper exit slip is evidence that connects a library attendee's departure to a recorded hostel arrival. This project digitizes that handoff, rather than building a book lending system or face recognition engine. Existing face-scan results become attendance records. Only an eligible attendee receives a unique, one-use exit token. Assigned hostel staff verify it, recording the return atomically with the token state and audit event. A pending record means **no return recorded**, not proof of physical absence.

The supplied 44-page report is the requirements reference; its code is a reference implementation. No instructions within the report are treated as user commands. This implementation preserves its eight-entity model, business rules and DBMS deliverables while improving usability, concurrency and session-bound staff identity.

## Requirements and invariants
- Eight relational entities: HOSTEL, STUDENT, STAFF, LIBRARY_SESSION, NIGHT_ATTENDANCE, EXIT_PASS, HOSTEL_RETURN, AUDIT_LOG.
- One attendance per student/session, one pass per attendance and one return per pass, enforced by unique constraints.
- Issue only for active students in active hostels, PRESENT/LATE attendance, an OPEN session, at or after the attendance deadline and strictly before closing. Never issue before the recorded scan.
- Expiry is closing + 15 minutes. Verification at expiry is accepted; after expiry rejected. Verification before issue rejected.
- Only authenticated active HOSTEL_STAFF in the student's assigned hostel may verify. Library staff/admin manage attendance and sessions; students issue/view only their own passes.
- Return insert, automatic USED state, and audit insert share a transaction. Duplicate simultaneous operations produce a controlled rejection.
- Calculated expiry is visible without waiting for a scan. CANCELLED remains distinct from EXPIRED.
- Classroom time simulation is explicit and server-controlled: exit = closing - 12 minutes; return = issued + 6 minutes. No browser-controlled timestamps in pass endpoints.
- Biometric integration, real institutional identities, VTOP, alerts and official deployment are outside this prototype.

## Architecture
A local Python Flask application renders responsive server-side HTML. The service layer owns transactions and authorization. SQLite is a runnable demonstration backend with the same domain constraints and transactional triggers. Oracle remains the academic backend: the application calls PL/SQL procedures for issuance/verification, with SELECT FOR UPDATE and uniqueness as concurrency safeguards. Database timestamps use campus-local naive Asia/Kolkata time consistently; Oracle sessions are set to +05:30. SQLite is explicitly labeled and never presented as Oracle runtime evidence.

Prototype login uses one environment-configured shared password and synthetic usernames (registration number for students, staff username for staff). This establishes workflow roles for demonstration; institutional authentication is future work. CSRF tokens protect state-changing forms. No public hosting is planned for this local database project.

## Execution phases
1. **Understand and design:** read every report chapter and code listing; map FR-01..15 and BR-01..12; record decisions and limits. Deliver this plan and ERD.
2. **Database:** create constraints, indexes, transactional audit/state triggers, repeatable non-destructive initialization and synthetic seeds. Preserve Oracle procedures, functions, cursor, DML and 20 reporting queries.
3. **Workflow services:** implement issuance, status calculation, hostel validation and return recording; bind staff identity to login and serialize conflicting operations.
4. **Application:** login, session-filtered dashboard, student passes and QR, staff verification, attendance registration, session management, master records, pending reports, CSV export and audit history.
5. **Verification:** integration tests against an isolated SQLite database for success, wrong hostel/role, missing/absent attendance, duplicate/racing requests, expiry boundaries, rollback, authorization and CSRF. Browser QA for real forms and responsive layout.
6. **Delivery:** runnable local server, setup guide, demo script and Oracle evidence checklist. Oracle compilation/execution stays explicitly unverified until an accessible Oracle instance is supplied.

## Acceptance mapping
| Requirements | Implementation |
| --- | --- |
| FR-01..03 reference data | Admin records page, validated forms, normalized tables |
| FR-04 sessions | Session form and status controls; timestamp ordering constraint |
| FR-05 attendance | Library/admin attendance page; unique student/session |
| FR-06..08 issuance | Student workflow and transactional service / Oracle procedure |
| FR-09..12 return and audit | Authenticated verifier, token validation, return trigger |
| FR-13 metrics | Session filter, attendance/pass/return/pending dashboard |
| FR-14 pending report | Reports page, CSV and Oracle explicit cursor |
| FR-15 interactive UI | Flask pages and QR PNG download |

## Deferred production work
Institution-approved identity and attendance integration, HTTPS deployment, rate limiting, dedicated least-privilege Oracle grants, restricted audit access, retention policy and operational monitoring. QR camera scanning is optional progressive enhancement; USB scanners/paste work everywhere. Real Oracle test evidence must come from an actual Oracle execution.


## Hardening revision (27 October 2026)

The original prototype boundary above is superseded for accounts, source ingestion and deployment configuration by the user's hardening request. Implemented: individual hashed accounts, revocable sessions and OIDC binding, HMAC attendance API, audited directory editing/archival, pass-hostel snapshots, hardened production settings, Oracle deployment migrations/grants/verification runner, Gunicorn/container/TLS configuration and additional tests. Approval-dependent infrastructure, actual provider connection, physical-device QA and real rollout are explicitly deferred at the user's direction. `DEPLOYMENT.md` is the current release handoff; the earlier prototype assumptions are retained as design history.
