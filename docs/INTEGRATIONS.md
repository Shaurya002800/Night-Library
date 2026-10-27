# Approved attendance integration contract

The application accepts outcomes from an existing approved attendance source. It does not implement face recognition, scrape VTOP or infer student identity from a camera. An upstream face-scan/VTOP connector can deliver this contract when the institution provides the authorized source API.

POST `/api/v1/attendance` over HTTPS using `Content-Type: application/json`:

```json
{"event_id":"source-event-123","student_id":"APPROVED_ID","session_id":1010,"scan_time":"2026-10-27T21:31:00+05:30"}
```

Exactly these four keys are accepted. `event_id` is 1–80 ASCII letters/digits/underscore/period/colon/hyphen. `session_id` is an integer. `scan_time` includes a timezone, and is normalized to campus time. Session, student and assigned hostel must be eligible. PRESENT/LATE is derived from the scan/deadline comparison; the sender cannot choose arbitrary attendance status. Scans after closing, over 60 seconds in the future, or older than ATTENDANCE_MAX_DELAY_SECONDS (default 3600) are rejected.

Headers:

- `X-Library-Timestamp`: current Unix epoch seconds; must be within five minutes of server time.
- `X-Library-Signature`: lowercase hex HMAC-SHA256 using ATTENDANCE_WEBHOOK_SECRET over `timestamp + "." + exact_body_bytes`.

No browser session or staff ID authenticates this API. CSRF is intentionally not used for this server-to-server endpoint; the HMAC authenticates the complete body and timestamp. Protect and rotate the shared integration secret through the approved secret-management system. During rotation coordinate sender and receiver because only the configured current secret is accepted.

A minimal sender signing example (transport is deliberately not invoked):

```python
import hashlib, hmac, json, os, time
body = json.dumps(event, separators=(",", ":")).encode()
timestamp = str(int(time.time()))
signature = hmac.new(
    os.environ["ATTENDANCE_WEBHOOK_SECRET"].encode(),
    timestamp.encode() + b"." + body,
    hashlib.sha256,
).hexdigest()
# Send exact `body` and the two headers to the approved HTTPS application origin.
```

Response contract:

| Status | Meaning / sender action |
| --- | --- |
| 201 | Attendance recorded; receipt includes attendance_id |
| 200 | Same event_id and exact body were already recorded; no second row |
| 400 | Invalid payload, time or eligibility; correct the upstream issue |
| 401 | Missing/invalid signature or stale delivery timestamp |
| 409 | Event ID reused with changed body, or attendance already supplied by another event |
| 429 | Delivery-rate limit reached; retry with backoff and a fresh signature |
| 503 | Integration is unconfigured or the database operation failed; retry with backoff |

Persist the original serialized body for retries. A retry uses the same event ID and exact body with a fresh delivery timestamp/signature. Deduplication and attendance insertion commit together, preventing partially saved receipts.

The provider identifier is trusted deployment configuration, not a sender-selected privilege. This first version supports one approved source/secret at a time. Reconciliation of historical attendance and bulk roster migration requires a separately reviewed import process; late events are not silently accepted.
