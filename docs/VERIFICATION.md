# Verification record

Date: 27 October 2026 (Asia/Kolkata)

## Initial demo verification (before hardening)

- `.venv/bin/python -m pytest -q` — **30 passed**. Tests use isolated temporary SQLite databases.
- `.venv/bin/python -m compileall -q app.py nightlibrary` — passed.
- Flask test-client checks: login, role authorization, dashboard, attendance, sessions, reports/CSV, audit, records and QR PNG response.
- Transactional checks: duplicate and simultaneous issuance/scans, wrong hostel/role, inactive staff/student/hostel, absent/missing attendance, cancellation, issue/expiry boundaries, pre-scan/pre-issue rejection and trigger rollback.
- Session security: CSRF protection, active-account recheck, student pass privacy and server-bound verifier identity.
- Browser walkthrough on the real local Flask server: sign in as student `24BCE1013`, generate a pass, inspect QR, sign in as matching `hostel_staff_03`, verify return and inspect updated dashboard. The returned pass is USED and the pending count falls from eight to seven.
- Browser visual review: dashboard, student QR pass and verification form/result.
- Responsive check at 390 × 844: document width 390, viewport width 390 after correcting the hidden-label overflow. Tables retain their own horizontal scrolling; mobile navigation scrolls and sign-out remains accessible. Viewport override restored afterward.

Screenshots in `docs/screenshots/` are actual SQLite-demo browser captures, not Oracle screenshots:

- `student-pass.png`: generated QR pass before return.
- `verified-return.png`: successful matching-hostel verification.
- `dashboard.png`: overview after return.
- `mobile-dashboard.png`: mobile layout after overflow correction.

The included local database retains this QA transaction. Use fresh student `24BCE1014` and matching staff username `hostel_staff_04` for your next walkthrough. Shared prototype password: `library-demo`. The login-page shortcuts use this fresh pair.

## External checks not executed

Oracle schema compilation, PL/SQL execution, Oracle concurrent-session tests and Flask-to-Oracle connectivity require a configured Oracle database. No Oracle service or credentials were supplied. `sql/oracle/verify_install.sql` and `docs/ORACLE_EVIDENCE.md` identify the remaining checks. Source review does not substitute for Oracle runtime verification.

Camera permission/device scanning has not been exercised; supported browsers can use native QR detection, with paste/USB input as the fallback. Public deployment and real identity/biometric integrations are outside this local prototype.

## Hardening verification update

- Python integration suite: **73 passed**. This includes the original workflow tests plus password hashing, individual credentials, logout/password-reset revocation, session expiry, persistent throttling, trusted hosts, HTTPS/secure-cookie enforcement, unsafe production configuration rejection, no production seeding, signed attendance ingestion and rejection/idempotency cases, edit/archive/restore, snapshot preservation and Oracle pool lifecycle through a driver mock.
- Scanner logic: **8 passed** using `node --test tests/scanner.test.cjs`. Simulated camera/decoder tests cover successful capture, malformed QR, unsupported browser, denied camera, delayed camera response after navigation, local photo decode, oversized image rejection and camera cleanup when backgrounded.
- OIDC account binding and rejection logic is tested with a mocked provider. This does not claim an actual provider login or physical camera test.
- Syntax compilation, JavaScript parsing, `git diff --check` and `pip check` passed.
- Oracle install scripts are parsed by tests; no Oracle execution took place. The real runner is `scripts/verify_oracle.py`. Docker's daemon is not running; container build/runtime/TLS remain untested.
- Python dependency auditing was attempted with pip-audit, but PyPI DNS/network access was unavailable. The audit did **not** complete. CI includes a required audit command for a connected environment.
- No new live browser server was started during hardening because the user asked to leave steps requiring new approval. New pages are covered through actual Flask test-client requests. Earlier screenshots demonstrate the initial SQLite UI, not every hardening change.

See `DEPLOYMENT.md` and `INTEGRATIONS.md` for the operator handoff. The application is a tested deployment candidate; these local checks do not certify the real campus installation as production-ready.
