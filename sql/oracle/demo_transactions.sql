/*
Run AFTER review_ii.sql has completed successfully.
Demonstrates pass generation, hostel verification, trigger updates, functions,
and cursor reporting. The timestamps are derived from session 1010 so the
demo remains internally consistent when run later; this is simulated data.
*/
SET SERVEROUTPUT ON;
DECLARE
v_pass_token EXIT_PASS.pass_token%TYPE;
v_result VARCHAR2(300);
v_closing LIBRARY_SESSION.closing_time%TYPE;
v_exit_time TIMESTAMP;
v_return_time TIMESTAMP;
BEGIN
SELECT closing_time
INTO v_closing
FROM LIBRARY_SESSION
WHERE session_id = 1010;
v_exit_time := v_closing - NUMTODSINTERVAL(12, 'MINUTE');
v_return_time := v_exit_time + NUMTODSINTERVAL(6, 'MINUTE');
DBMS_OUTPUT.PUT_LINE('--- Transaction A: Generate digital exit pass ---');
PR_GENERATE_EXIT_PASS(
p_student_id => '24BCE1013',
p_session_id => 1010,
p_pass_token => v_pass_token,
p_event_time => v_exit_time
);
DBMS_OUTPUT.PUT_LINE('Generated pass token: ' || v_pass_token);
DBMS_OUTPUT.PUT_LINE('--- Transaction B: Verify hostel return ---');
PR_VERIFY_HOSTEL_RETURN(
p_pass_token => v_pass_token,
p_staff_id => 'HST003',
p_result => v_result,
p_verified_at => v_return_time
);
DBMS_OUTPUT.PUT_LINE(v_result);
DBMS_OUTPUT.PUT_LINE('--- Transaction C: Check pass status ---');
DBMS_OUTPUT.PUT_LINE('Status after verification: ' || FN_CHECK_PASS_STATUS(v_pass_token, v_return_time));
COMMIT;
END;
/
PROMPT --- Cursor exception report for session 1010 ---
BEGIN
PR_GENERATE_UNRETURNED_REPORT(1010);
END;
/
PROMPT --- Confirm trigger result: returned pass status should be USED ---
SELECT ep.pass_id, ep.pass_token, ep.pass_status, hr.arrival_time, hr.verified_by
FROM EXIT_PASS ep
JOIN NIGHT_ATTENDANCE na ON na.attendance_id = ep.attendance_id
LEFT JOIN HOSTEL_RETURN hr ON hr.pass_id = ep.pass_id
WHERE na.student_id = '24BCE1013'
AND na.session_id = 1010;
PROMPT --- Latest automatic audit records ---
SELECT log_id, entity_type, entity_id, action_name, performed_by, action_time, details
FROM AUDIT_LOG
ORDER BY log_id DESC
FETCH FIRST 10 ROWS ONLY;
