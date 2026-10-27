SET SERVEROUTPUT ON;
PROMPT Invalid objects (expect no rows)
SELECT object_name, object_type, status FROM user_objects
WHERE object_type IN ('PROCEDURE','FUNCTION','TRIGGER') AND status <> 'VALID';
PROMPT Compilation errors (expect no rows)
SELECT name,type,line,position,text FROM user_errors ORDER BY name,sequence;
PROMPT Tables and row counts
SELECT 'HOSTEL' table_name,COUNT(*) row_count FROM hostel
UNION ALL SELECT 'STUDENT',COUNT(*) FROM student
UNION ALL SELECT 'STAFF',COUNT(*) FROM staff
UNION ALL SELECT 'LIBRARY_SESSION',COUNT(*) FROM library_session
UNION ALL SELECT 'NIGHT_ATTENDANCE',COUNT(*) FROM night_attendance
UNION ALL SELECT 'EXIT_PASS',COUNT(*) FROM exit_pass
UNION ALL SELECT 'HOSTEL_RETURN',COUNT(*) FROM hostel_return
UNION ALL SELECT 'AUDIT_LOG',COUNT(*) FROM audit_log;
PROMPT Automatic return state
SELECT ep.pass_id,ep.pass_status,hr.verified_by,hr.arrival_time
FROM exit_pass ep JOIN hostel_return hr ON hr.pass_id=ep.pass_id;
PROMPT Latest audit events
SELECT * FROM audit_log ORDER BY log_id DESC FETCH FIRST 20 ROWS ONLY;
