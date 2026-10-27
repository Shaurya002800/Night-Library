# Night Library · Digital Exit & Hostel Return

A runnable local DBMS project that replaces the paper exit slip with a one-time QR pass linked to library attendance and a verified hostel return.

**Workflow:** attendance → eligible exit-pass issuance → verification by assigned hostel staff → return record + USED pass + audit event in one transaction.

The project follows the idea and rules in the supplied comprehensive report. The initial local-demo implementation has since been extended with account/session security, signed attendance ingestion, directory maintenance and a production deployment configuration. It includes a functional Flask application, a SQLite demonstration database, and Oracle SQL/PLSQL deliverables. All sample identities are synthetic.

## Production hardening

See `docs/DEPLOYMENT.md` for the hardened deployment configuration, account provisioning, Oracle migration and remaining external release gates. See `docs/INTEGRATIONS.md` for the signed upstream attendance API. Production disables demo accounts and manual attendance, requires Oracle/HTTPS/trusted hosts and persistent secrets, and never seeds synthetic records. This is a deployment candidate; Oracle, institutional integrations and hosting still need real environment validation.

## Run locally

The current locked deployment uses Python 3.14. Development source requires Python 3.10+; use a compatible dependency resolution if you choose an older interpreter. From this project directory:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.lock -r requirements-dev.txt
cp .env.example .env
.venv/bin/python app.py
```

Open **http://127.0.0.1:5050**. SQLite initializes and seeds automatically on first launch. Subsequent launches preserve records. The virtual environment and dependencies have already been installed in this workspace.

| Workspace | Username | Password |
| --- | --- | --- |
| Student with eligible attendance | `24BCE1014` | `library-demo` |
| Matching hostel staff, MH-D | `hostel_staff_04` | `library-demo` |
| Wrong-hostel staff, MH-B | `hostel_staff_02` | `library-demo` |
| Library staff | `library_staff_01` | `library-demo` |
| Administrator | `sys_admin` | `library-demo` |

The password can be changed globally through `DEMO_PASSWORD`. These demo accounts store hashes and are seeded only in explicitly enabled development/demo mode. Production uses individually provisioned passwords or approved OIDC identities. Set `FLASK_SECRET_KEY` in `.env` for persistent signed sessions across restarts; if empty, a random per-process key invalidates sessions when restarting.

## Walk through the idea

1. Sign in as `24BCE1014`, open **My exit passes**, select session `1010`, and generate the pass. Attendance and eligibility are checked. Save or copy the token.
2. Sign out and sign in as `hostel_staff_02`. Attempt verification: the wrong hostel is rejected without recording a return.
3. Sign in as `hostel_staff_04`. Enter the same token: one return is recorded, the pass becomes `USED`, and a trigger writes the audit event. Reusing it is rejected.
4. Sign in as `sys_admin`. Review the dashboard, pending-return report, CSV export and audit trail. Pending counts include eligible attendees who have not received a pass.
5. Library/admin users can add attendance (try `24BCE1019` in session `1010`), create sessions and change their state. Admins can add hostel, student and staff reference records.

The saved browser QA walkthrough used `24BCE1013` / `hostel_staff_03`; that return is already recorded in the included local database. The Student and Hostel staff shortcuts use the fresh `24BCE1014` / `hostel_staff_04` pair.

After this walkthrough, use another seeded eligible student (`24BCE1015` with `hostel_staff_05`, for example). Each attendance deliberately receives at most one pass; an existing pass remains accessible in the student's history.

### Time simulation

`DEMO_MODE=true` enables classroom demonstrations during the day. Issuance uses session closing minus 12 minutes; verification uses issue time plus 6 minutes. This is prominently labeled in the UI. With `DEMO_MODE=false`, issuance and verification use server time in Asia/Kolkata. Browsers cannot submit event times to those endpoints. Seed dates are set at initial database creation and are not silently refreshed on later days.

A pass expires at closing + 15 minutes. Verification exactly at expiry is allowed; one second later is rejected. Issuance exactly at the attendance deadline is allowed; at closing it is rejected. A pass cannot precede its attendance scan.

### QR input

A pass can be downloaded as a PNG and read by any QR reader. USB scanner input and copy/paste are supported. Camera and photo scanning use the browser’s native `BarcodeDetector` when available, with a paste/USB fallback. Frames/photos stay on-device. JavaScript tests cover capture, cleanup, rejected camera access and unavailable decoders using simulated hardware; physical device capture remains an operator acceptance check.

## Oracle backend

Oracle is the academic SQL/PLSQL backend; SQLite is explicitly a local demo fallback. No Oracle execution evidence is claimed in this workspace.

1. Create or use an **empty, dedicated development schema** in Oracle Database 19c+ / XE / Free. The setup script creates objects; it never automatically drops existing tables.
2. For the classroom seed only, in SQL Developer run `sql/oracle/review_ii.sql` using **Run Script (F5)**. It creates eight tables, five sequences (including attendance/session management), indexes, three procedures, two functions, two triggers, seed records, DML examples and twenty queries. It stops on SQL errors. Initial counts: 10 hostels, 20 students, 12 staff, 10 sessions, 18 attendances, 12 passes, 10 returns, 22 audit events.
3. Run `sql/oracle/002_hardening.sql` once, then `sql/oracle/verify_install.sql`. Check that there are no invalid objects or compilation errors. A script reaching its last line alone is not proof of successful PL/SQL compilation.
4. Configure `.env`:

```dotenv
DATABASE_BACKEND=oracle
DB_USER=your_development_schema
DB_PASSWORD=your_password
DB_DSN=localhost:1521/FREEPDB1
DEMO_MODE=true
```

5. Restart the Flask app. The header displays **ORACLE**. Issuance/verification call the stored procedures; the caller controls commit/rollback.
6. Run `sql/oracle/demo_transactions.sql` for the SQL-only walkthrough, or use the application. The SQL script uses `24BCE1013` and `HST003`; choose a fresh student/session if that attendance was already used through the application.
7. Run `sql/oracle/queries.sql` for the independent reporting catalogue and retain actual SQL Developer outputs using `docs/ORACLE_EVIDENCE.md`.

The schema account needs normal table/sequence/procedure/trigger creation privileges and a tablespace quota. The driver uses thin mode and does not require an Oracle Instant Client for a supported database. The application sets the Oracle session time zone to `+05:30`; local naive timestamps are interpreted as campus time throughout the model.

## Verification

```sh
.venv/bin/python -m pytest -q
```

Tests create isolated temporary databases and leave your demo data alone. They cover successful transitions, duplicate/replayed/concurrent requests, wrong or inactive staff, missing/absent/inactive attendance, timing boundaries, cancelled/expired passes, database constraints, trigger rollback, CSRF, student data access, server-bound staff identity, attendance/session/master-data forms and CSV formula escaping.

Browser QA verifies the actual local forms separately. See `docs/VERIFICATION.md` for results and limitations.

Additional verification: `node --test tests/scanner.test.cjs` runs scanner state-machine tests. The production deployment and integration tests are documented separately; CI is configured but has not been run remotely.

## Files

- `docs/IMPLEMENTATION_PLAN.md` — idea, business rules, phases and acceptance mapping.
- `docs/ERD.md` — relational relationships.
- `app.py` — Flask routes, login roles, form protection and views.
- `nightlibrary/db.py` — database connections and non-destructive SQLite initialization.
- `nightlibrary/service.py` — transactional workflow and calculated status.
- `sql/sqlite_schema.sql` — demo constraints, indexes and triggers.
- `sql/oracle/` — Oracle schema, seeds, procedures/functions/cursor/triggers, SQL reports and evidence checks.
- `templates/`, `static/` — responsive application UI.
- `tests/` — integration and transaction tests.
- `instance/night_library.db` — local demo data, ignored by Git.

## Scope

This is an unofficial project with a local demo and a hardened deployment configuration. It consumes attendance outcomes rather than implementing face recognition. The signed attendance API and OIDC adapter still require approved institutional systems. Security mechanisms are implemented, but a real rollout still requires successful Oracle/TLS/provider/device verification, vulnerability scans, backup restoration testing and institutional operational ownership. A pending database record does not prove physical absence. Master records can be edited, archived and restored through the UI. Physical deletion is intentionally replaced by reversible archival to preserve linked evidence. Accounts can be provisioned using the CLI; password changes revoke existing sessions.

To obtain a fresh SQLite dataset without deleting existing work, stop the server, set `SQLITE_PATH` to a new file in `.env`, then restart. Do not replace your existing file unless its records are no longer needed.
