# Deployment candidate and operator handoff

This application is hardened for a controlled deployment, but it is **not certified production-ready** until the environment-specific checks below pass. Per the user's instruction, work requiring additional approvals or external account setup has been left for the operator. No server, campus identity provider, attendance source, public domain, or real student records were connected.

## Completed in code

- Independent accounts with Werkzeug scrypt hashes; interactive password provisioning and recovery, password-change form, and explicit institutional OIDC subject bindings.
- Server-revocable sessions, four-hour absolute lifetime, thirty-minute idle expiry, session invalidation after password or directory/role changes, database-backed login/verification throttling.
- CSRF-protected browser mutations; authenticated HMAC attendance ingestion with a five-minute delivery-signature window, event deduplication, timestamp/eligibility checks, and transactional source audit.
- Administration editing, reversible archival/restoration, self/last-admin protection, pass cancellation with reason, and preserved history. Records with dependencies are archived instead of physically deleting historical evidence.
- Issued-hostel snapshots protect pass ownership across later reassignment. Admin UI rejects reassignment while an active pass remains unresolved.
- HTTPS enforcement, secure HttpOnly/SameSite cookies, trusted host validation, CSP without inline scripts or external CDNs/fonts, security headers, bounded form bodies, non-sensitive request logging, pooled Oracle connections and database readiness checks.
- Separate schema-only installation with no synthetic roster, Oracle hardening migration and runtime account grants; synthetic credentials and automatic seeding are forbidden in production.
- Gunicorn WSGI entry point, container setup, Caddy HTTPS proxy, runtime dependency version lock and CI test/audit/build workflow.

## Prepare Oracle with your DBA

Use Oracle 19c+ or a supported Oracle Free database. Do not use the demo setup script for real records.

1. Create separate schema-owner and runtime accounts using your DBA's credential process. The owner needs a direct EXECUTE grant on SYS.DBMS_CRYPTO for the hardened pass-token procedure (`sql/oracle/dba_prerequisites.sql`); the runtime user does not. Tokens use 128 cryptographically random bits in the hardened Oracle procedure, rather than relying on GUID unpredictability. Passwords do not belong in scripts or chat.
2. As the owner, run `sql/oracle/001_schema.sql`, then `sql/oracle/002_hardening.sql`, using SQL Developer F5. Existing classroom schemas can apply `002_hardening.sql` once; already-applied migrations must not be rerun. Oracle DDL is not transactional: take a backup/snapshot first. Both migration versions 1 and 2 must be present.
3. Check USER_OBJECTS and USER_ERRORS with `verify_install.sql`. Production adds authentication, ingestion, security-event and migration tables and a hostel-snapshot trigger to the eight domain tables.
4. Review `runtime_grants.sql`, replace its APP_USER definition with the actual runtime username, and execute as owner. Runtime has no audit UPDATE/DELETE, no domain DELETE, no schema DDL and no direct HOSTEL_RETURN INSERT privileges. Provide CREATE SESSION separately through the DBA. Set DB_SCHEMA to the owner, so unqualified SQL resolves correctly.
5. Production requires a `tcps://` Oracle DSN with server-name validation enabled. Set the appropriate trusted certificate/wallet configuration according to the institution's network policy. If a wallet is required, mount it read-only into the app container and configure DB_WALLET_PATH/DB_WALLET_PASSWORD through approved secrets; no wallet files are included in the image. Validate the connection in the deployment network. Restrict listener access to approved hosts; do not expose Oracle publicly.
6. In a separate **disposable test schema**, run the acceptance runner below. It creates no fake screenshots and fails rather than declaring success when Oracle is unavailable.

```sh
# Supply ORACLE_TEST_USER, ORACLE_TEST_PASSWORD and ORACLE_TEST_DSN through protected environment.
.venv/bin/python scripts/verify_oracle.py --install --output oracle-verification.json
```

`--install` refuses nonempty schemas and never drops data. The runner leaves its synthetic evidence records in the test schema. Use a new test schema for a new install run. It tests actual PL/SQL compilation, issuance, wrong hostel, return/replay, trigger/audit effects, rollback, expiry, status functions, explicit cursor and concurrency. Test Flask against Oracle separately before real release; the local SQLite suite does not prove Oracle compatibility.

## Provision the first administrator and accounts

The clean schema has only a disabled SYS001 system-audit actor. It cannot log in.

Use a shell with the approved Oracle settings loaded. Keep the deployment app stopped until initial setup is complete. The CLI application factory requires a valid configuration and completed migration, but opens no web listener.

```sh
.venv/bin/flask --app 'app:create_app()' bootstrap-admin \
  --staff-id ADM001 --username campus_admin --name 'Campus administrator'
```

The password is prompted with hidden input and confirmation. No default production password exists. Log in and add approved hostels/students/staff through Reference records. Then provision each directory subject:

```sh
.venv/bin/flask --app 'app:create_app()' create-account \
  --username student_login --kind student --subject-id APPROVED_ID
# Or explicitly bind an approved identity-provider subject, never an email heuristic:
.venv/bin/flask --app 'app:create_app()' create-account \
  --username staff_login --kind staff --subject-id HST001 --oidc-sub APPROVED_OPAQUE_SUBJECT
```

Use `reset-password --username ...` only through the restricted operator environment. It revokes all sessions. Application password changes also revoke all sessions. OIDC accounts are mapped by exact issuer + subject and must be explicitly provisioned. Email claims never create or link privileged accounts.

## Configure institutional sign-in and attendance

Use `.env.production.example` as a template for a local `.env.production` secret file. It is ignored by Git and excluded from the image. Provision independent random secrets (at least 32 characters); do not reuse a database password as a cookie/webhook secret.

Register the exact callback `https://YOUR_HOST/auth/callback` with your approved OIDC provider. Configure issuer, HTTPS discovery URL, client ID and client secret. `AUTH_MODE=oidc` disables local password login; use `local` for initial provisioning if SSO is not yet registered, then enable the intended mode. Confirm the provider's MFA and offboarding policies. Authlib handles authorization-code flow with PKCE, state, nonce and ID-token validation; the app also checks the exact configured issuer and preprovisioned subject.

Have the approved upstream attendance system deliver signed events following `INTEGRATIONS.md`. Production manual attendance POSTs are disabled. This project does not bypass VTOP or introduce unapproved biometric capture. Only attendance outcomes and identifiers are imported; no face images or biometric templates are collected.

## Deploy

1. In an authorized build/network environment, install/audit the version lock, run Python and JavaScript tests, and build the image. CI configuration is supplied but has not run remotely.
2. Scan the application and base images before release. The Python dependency audit could not contact PyPI in this workspace; no clean-vulnerability claim is made. Pin reviewed base/proxy image digests for your release after scanning.
3. Configure `.env.production`, PUBLIC_HOST/DNS, firewall rules, Oracle access, and certificate eligibility. TRUSTED_HOSTS must contain the public hostname and `127.0.0.1` for the private container readiness check. PUBLIC_BASE_URL must exactly match the HTTPS public origin.
4. Start the supplied compose configuration on the approved server:

```sh
PUBLIC_HOST=YOUR_APPROVED_HOST docker compose -f compose.production.yml up -d --build
```

Only Caddy exposes ports. Gunicorn is on the private compose network. PROXY_HOPS=1 is safe only while the application port remains inaccessible to untrusted clients. Do not independently publish port 8000 or trust arbitrary forwarding headers. Caddy requests TLS certificates as part of deployment; this network/domain step was not performed here.

5. Check `/health` for process liveness and `/ready` for database/migration readiness. Exercise real login, pass issuance, wrong-hostel rejection, one successful scan, replay rejection, ingestion deduplication and audit evidence. Record evidence before opening access to a real roster.
6. Test Android/iOS browser camera permissions, physical QR capture and USB scanner input. The scanner uses native BarcodeDetector and provides token/USB fallback; browsers without native detection need an approved QR reader. Images/frames stay on-device. Eight JavaScript state-machine tests use simulated hardware, not an actual camera.

The Docker build and HTTPS stack have not been executed here because the Docker daemon is not running. Providing configuration is not evidence that it is deployed or operational.

## Operations

- Use institution-approved encrypted Oracle backups (RMAN/Data Pump as appropriate), protected off-host storage and documented retention. Perform a real restoration rehearsal in a separate environment; do not consider an untested export a recovery plan.
- Retain append-only pass/return and security events under the institution's policy. Runtime credentials cannot update/delete the two audit tables. DBA access and backups still require separate access controls and monitoring.
- Schedule `flask --app 'app:create_app()' maintenance` through the approved operations scheduler to purge expired authentication sessions and throttle buckets. It never deletes attendance, passes, returns or audit history. No background automation was created here.
- Monitor readiness, 5xx rates, Oracle pool saturation and authentication failures in your operations system. Request logs include a correlation ID, endpoint name, method, status and duration; URL paths, QR tokens, authorization codes and passwords are excluded.
- Roll back the application to the prior reviewed image if needed. Do not reverse migrations against live data without a DBA-reviewed plan and verified backup; the hardening migration adds tables/columns and preserves the domain history.
- Review retention/erasure, incident response and institutional authorization before using real student data. These organization-specific decisions cannot be completed by code alone.

## Release gates still requiring external work

Actual Oracle acceptance and Flask integration; approved provider registration/feed contract; physical camera checks; dependency and container vulnerability scans in a connected environment; container/TLS/host deployment verification; backup/restore and operational ownership. The user asked to leave approval-dependent work, so these remain explicit handoff items, not claimed completions.

Implementation references: [Flask security](https://flask.palletsprojects.com/en/stable/web-security/), [Flask proxy trust](https://flask.palletsprojects.com/en/stable/deploying/proxy_fix/), [Authlib OIDC](https://docs.authlib.org/en/latest/oauth2/client/web/flask.html), [Oracle connection pooling](https://python-oracledb.readthedocs.io/en/latest/user_guide/connection_handling.html).
