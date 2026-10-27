# Oracle execution evidence checklist

Oracle is not available in the current workspace. The SQL files are supplied for execution; no live Oracle success or screenshots are fabricated. SQLite tests verify the local implementation, not Oracle compilation or database compatibility.

Use an empty dedicated Oracle development schema. Run `review_ii.sql` with F5, then `verify_install.sql`; inspect both USER_OBJECTS and USER_ERRORS. If an object fails compilation, stop and resolve the actual reported error before treating setup as successful.

| Evidence | Capture from your actual Oracle environment |
| --- | --- |
| E01 | Successful creation of eight tables, five sequences, three procedures, two functions, two triggers and indexes |
| E02 | DESCRIBE tables and inspect PK/FK/UNIQUE/CHECK constraints |
| E03 | All eight table counts, each at least ten after seed activity |
| E04 | Join, aggregate, NOT EXISTS and pending-return query results |
| E05 | PR_GENERATE_EXIT_PASS output and ACTIVE pass row |
| E06 | Matching verification output, one return row and USED pass state |
| E07 | FN_CHECK_PASS_STATUS, FN_GET_STUDENT_RETURN_STATUS and explicit cursor output |
| E08 | PASS_ISSUED and RETURN_VERIFIED audit events |
| E09 | Flask UI using ORACLE backend and matching persisted rows |
| E10 | Duplicate issuance, wrong hostel, expiry and repeated scan rejection |
| E11 | Rollback before commit removes return plus trigger changes |
| E12 | Two concurrent sessions issue/verify the same attendance/pass; only one succeeds |

The report's original three sequences are retained; two additional sequences support attendance and session creation from the UI. Row locking and unique constraints protect issuance and verification. Procedures do not commit. Example event-time parameters support the classroom script; they must be restricted to trusted callers in a real deployment.
