-- Q1. Attendance details with student, hostel and session.
SELECT na.attendance_id, st.student_id, st.student_name, h.hostel_name,
na.session_id, na.scan_time, na.attendance_status
FROM NIGHT_ATTENDANCE na
JOIN STUDENT st ON st.student_id = na.student_id
JOIN HOSTEL h ON h.hostel_id = st.hostel_id
ORDER BY na.session_id, st.student_id;
-- Q2. Total active students in each hostel.
SELECT h.hostel_name, COUNT(st.student_id) AS active_students
FROM HOSTEL h
LEFT JOIN STUDENT st ON st.hostel_id = h.hostel_id AND st.student_status = 'ACTIVE'
GROUP BY h.hostel_name
ORDER BY active_students DESC;
-- Q3. Stored ACTIVE passes; FN_CHECK_PASS_STATUS evaluates time-aware validity.
SELECT pass_id, pass_token, issued_at, expiry_time, pass_status
FROM EXIT_PASS
WHERE pass_status = 'ACTIVE'
ORDER BY issued_at DESC;
-- Q4. Students whose hostel return has been verified.
SELECT st.student_id, st.student_name, h.hostel_name, hr.arrival_time, hr.verified_by
FROM HOSTEL_RETURN hr
JOIN EXIT_PASS ep ON ep.pass_id = hr.pass_id
JOIN NIGHT_ATTENDANCE na ON na.attendance_id = ep.attendance_id
JOIN STUDENT st ON st.student_id = na.student_id
JOIN HOSTEL h ON h.hostel_id = hr.hostel_id
WHERE hr.verification_status = 'VERIFIED'
ORDER BY hr.arrival_time DESC;
-- Q5. Attendance records without a corresponding verified return.
SELECT st.student_id, st.student_name, na.session_id, ep.pass_token
FROM NIGHT_ATTENDANCE na
JOIN STUDENT st ON st.student_id = na.student_id
LEFT JOIN EXIT_PASS ep ON ep.attendance_id = na.attendance_id
LEFT JOIN HOSTEL_RETURN hr ON hr.pass_id = ep.pass_id AND hr.verification_status = 'VERIFIED'
WHERE na.attendance_status IN ('PRESENT', 'LATE')
AND hr.return_id IS NULL
ORDER BY na.session_id, st.student_id;
-- Q6. Returns recorded after the session closing time.
SELECT st.student_id, st.student_name, hr.arrival_time, ls.closing_time
FROM HOSTEL_RETURN hr
JOIN EXIT_PASS ep ON ep.pass_id = hr.pass_id
JOIN NIGHT_ATTENDANCE na ON na.attendance_id = ep.attendance_id
JOIN STUDENT st ON st.student_id = na.student_id
JOIN LIBRARY_SESSION ls ON ls.session_id = na.session_id
WHERE hr.arrival_time > ls.closing_time;
-- Q7. Attendance totals by night-library session.
SELECT ls.session_id, ls.session_date,
COUNT(na.attendance_id) AS attendance_records,
SUM(CASE WHEN na.attendance_status = 'LATE' THEN 1 ELSE 0 END) AS late_arrivals
FROM LIBRARY_SESSION ls
LEFT JOIN NIGHT_ATTENDANCE na ON na.session_id = ls.session_id
GROUP BY ls.session_id, ls.session_date
ORDER BY ls.session_date;
-- Q8. Students with more than one attendance record.
SELECT st.student_id, st.student_name, COUNT(*) AS sessions_attended
FROM NIGHT_ATTENDANCE na
JOIN STUDENT st ON st.student_id = na.student_id
WHERE na.attendance_status IN ('PRESENT', 'LATE')
GROUP BY st.student_id, st.student_name
HAVING COUNT(*) > 1;
-- Q9. Session(s) with the highest attendance count (subquery).
SELECT session_id, attendance_count
FROM (
SELECT session_id, COUNT(*) AS attendance_count
FROM NIGHT_ATTENDANCE
WHERE attendance_status IN ('PRESENT', 'LATE')
GROUP BY session_id
) totals
WHERE attendance_count = (
SELECT MAX(attendance_count)
FROM (
SELECT COUNT(*) AS attendance_count
FROM NIGHT_ATTENDANCE
WHERE attendance_status IN ('PRESENT', 'LATE')
GROUP BY session_id
) max_totals
);
-- Q10. Average number of attended sessions per active student.
SELECT ROUND(AVG(attended_count), 2) AS avg_sessions_per_active_student
FROM (
SELECT st.student_id, COUNT(na.attendance_id) AS attended_count
FROM STUDENT st
LEFT JOIN NIGHT_ATTENDANCE na
ON na.student_id = st.student_id
AND na.attendance_status IN ('PRESENT', 'LATE')
WHERE st.student_status = 'ACTIVE'
GROUP BY st.student_id
);
-- Q11. Count of passes by current stored status.
SELECT pass_status, COUNT(*) AS pass_count
FROM EXIT_PASS
GROUP BY pass_status
ORDER BY pass_status;
-- Q12. Approximate minutes from exit-pass issuance to hostel verification.
SELECT hr.return_id, ep.pass_token,
ROUND((CAST(hr.arrival_time AS DATE) - CAST(ep.issued_at AS DATE)) * 1440, 2) AS minutes_to_hostel
FROM HOSTEL_RETURN hr
JOIN EXIT_PASS ep ON ep.pass_id = hr.pass_id
ORDER BY hr.return_id;
-- Q13. Audit activity grouped by action.
SELECT action_name, COUNT(*) AS action_count
FROM AUDIT_LOG
GROUP BY action_name
ORDER BY action_count DESC;
-- Q14. Number of pending returns grouped by hostel.
SELECT h.hostel_name, COUNT(*) AS pending_students
FROM NIGHT_ATTENDANCE na
JOIN STUDENT st ON st.student_id = na.student_id
JOIN HOSTEL h ON h.hostel_id = st.hostel_id
LEFT JOIN EXIT_PASS ep ON ep.attendance_id = na.attendance_id
LEFT JOIN HOSTEL_RETURN hr ON hr.pass_id = ep.pass_id AND hr.verification_status = 'VERIFIED'
WHERE na.attendance_status IN ('PRESENT', 'LATE')
AND hr.return_id IS NULL
GROUP BY h.hostel_name
ORDER BY pending_students DESC;
-- Q15. Pass and return totals for each session.
SELECT ls.session_id,
COUNT(DISTINCT ep.pass_id) AS passes_issued,
COUNT(DISTINCT hr.return_id) AS verified_returns
FROM LIBRARY_SESSION ls
LEFT JOIN NIGHT_ATTENDANCE na ON na.session_id = ls.session_id
LEFT JOIN EXIT_PASS ep ON ep.attendance_id = na.attendance_id
LEFT JOIN HOSTEL_RETURN hr ON hr.pass_id = ep.pass_id AND hr.verification_status = 'VERIFIED'
GROUP BY ls.session_id
ORDER BY ls.session_id;
-- Q16. Students who have not attended the latest open session.
SELECT st.student_id, st.student_name
FROM STUDENT st
WHERE st.student_status = 'ACTIVE'
AND NOT EXISTS (
SELECT 1
FROM NIGHT_ATTENDANCE na
JOIN LIBRARY_SESSION ls ON ls.session_id = na.session_id
WHERE na.student_id = st.student_id
AND ls.session_status = 'OPEN'
AND na.attendance_status IN ('PRESENT', 'LATE')
)
ORDER BY st.student_id;
-- Q17. Audit trail for exit passes and returns, including staff identity.
SELECT al.log_id, al.entity_type, al.entity_id, al.action_name,
NVL(sf.staff_name, 'System') AS performed_by, al.action_time, al.details
FROM AUDIT_LOG al
LEFT JOIN STAFF sf ON sf.staff_id = al.performed_by
ORDER BY al.action_time DESC;
-- Q18. Passes that are stored as expired or whose active validity window has elapsed.
SELECT pass_id, pass_token, pass_status, expiry_time
FROM EXIT_PASS
WHERE pass_status = 'EXPIRED'
OR (pass_status = 'ACTIVE' AND expiry_time < LOCALTIMESTAMP)
ORDER BY expiry_time;
-- Q19. Hostel verification workload by staff member.
SELECT sf.staff_id, sf.staff_name, sf.hostel_id, COUNT(hr.return_id) AS verified_returns
FROM STAFF sf
LEFT JOIN HOSTEL_RETURN hr ON hr.verified_by = sf.staff_id
WHERE sf.staff_role = 'HOSTEL_STAFF'
GROUP BY sf.staff_id, sf.staff_name, sf.hostel_id
ORDER BY verified_returns DESC, sf.staff_id;
-- Q20. Demonstrate the status function for every attendance record in session 1010.
SELECT st.student_id, st.student_name,
FN_GET_STUDENT_RETURN_STATUS(st.student_id, 1010) AS return_status
FROM NIGHT_ATTENDANCE na
JOIN STUDENT st ON st.student_id = na.student_id
WHERE na.session_id = 1010
ORDER BY st.student_id;
