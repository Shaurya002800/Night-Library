-- Clean deployment schema. No synthetic students, sessions or hostel records.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK;
ALTER SESSION SET TIME_ZONE='+05:30';
CREATE TABLE HOSTEL (
hostel_id VARCHAR2(10) CONSTRAINT pk_hostel PRIMARY KEY,
hostel_name VARCHAR2(100) NOT NULL CONSTRAINT uq_hostel_name UNIQUE,
hostel_type VARCHAR2(10) NOT NULL,
capacity NUMBER(5) NOT NULL,
hostel_status VARCHAR2(10) DEFAULT 'ACTIVE' NOT NULL,
CONSTRAINT ck_hostel_type CHECK (hostel_type IN ('MEN', 'WOMEN', 'OTHER')),
CONSTRAINT ck_hostel_capacity CHECK (capacity > 0),
CONSTRAINT ck_hostel_status CHECK (hostel_status IN ('ACTIVE', 'INACTIVE'))
);
CREATE TABLE STUDENT (
student_id VARCHAR2(12) CONSTRAINT pk_student PRIMARY KEY,
student_name VARCHAR2(80) NOT NULL,
program VARCHAR2(60) NOT NULL,
year_of_study NUMBER(1) NOT NULL,
hostel_id VARCHAR2(10) NOT NULL,
room_no VARCHAR2(20) NOT NULL,
student_status VARCHAR2(10) DEFAULT 'ACTIVE' NOT NULL,
CONSTRAINT fk_student_hostel FOREIGN KEY (hostel_id) REFERENCES HOSTEL(hostel_id),
CONSTRAINT ck_student_year CHECK (year_of_study BETWEEN 1 AND 4),
CONSTRAINT ck_student_status CHECK (student_status IN ('ACTIVE', 'INACTIVE'))
);
CREATE TABLE STAFF (
staff_id VARCHAR2(10) CONSTRAINT pk_staff PRIMARY KEY,
staff_name VARCHAR2(80) NOT NULL,
staff_role VARCHAR2(20) NOT NULL,
hostel_id VARCHAR2(10),
username VARCHAR2(40) NOT NULL CONSTRAINT uq_staff_username UNIQUE,
is_active CHAR(1) DEFAULT 'Y' NOT NULL,
CONSTRAINT fk_staff_hostel FOREIGN KEY (hostel_id) REFERENCES HOSTEL(hostel_id),
CONSTRAINT ck_staff_role CHECK (staff_role IN ('LIBRARY_STAFF', 'HOSTEL_STAFF', 'ADMIN')),
CONSTRAINT ck_staff_active CHECK (is_active IN ('Y', 'N')),
CONSTRAINT ck_staff_hostel_role CHECK (
(staff_role = 'HOSTEL_STAFF' AND hostel_id IS NOT NULL) OR
(staff_role IN ('LIBRARY_STAFF', 'ADMIN'))
)
);
CREATE TABLE LIBRARY_SESSION (
session_id NUMBER(8) CONSTRAINT pk_library_session PRIMARY KEY,
session_date DATE NOT NULL CONSTRAINT uq_session_date UNIQUE,
start_time TIMESTAMP NOT NULL,
attendance_deadline TIMESTAMP NOT NULL,
closing_time TIMESTAMP NOT NULL,
session_status VARCHAR2(12) DEFAULT 'SCHEDULED' NOT NULL,
CONSTRAINT ck_session_status CHECK (session_status IN ('SCHEDULED', 'OPEN', 'CLOSED')),
CONSTRAINT ck_session_times CHECK (start_time < attendance_deadline AND attendance_deadline < closing_time)
);
CREATE TABLE NIGHT_ATTENDANCE (
attendance_id NUMBER(10) CONSTRAINT pk_night_attendance PRIMARY KEY,
student_id VARCHAR2(12) NOT NULL,
session_id NUMBER(8) NOT NULL,
scan_time TIMESTAMP DEFAULT LOCALTIMESTAMP NOT NULL,
attendance_status VARCHAR2(10) DEFAULT 'PRESENT' NOT NULL,
CONSTRAINT fk_attendance_student FOREIGN KEY (student_id) REFERENCES STUDENT(student_id),
CONSTRAINT fk_attendance_session FOREIGN KEY (session_id) REFERENCES LIBRARY_SESSION(session_id),
CONSTRAINT uq_attendance_student_session UNIQUE (student_id, session_id),
CONSTRAINT ck_attendance_status CHECK (attendance_status IN ('PRESENT', 'LATE', 'ABSENT'))
);
CREATE TABLE EXIT_PASS (
pass_id NUMBER(10) CONSTRAINT pk_exit_pass PRIMARY KEY,
attendance_id NUMBER(10) NOT NULL CONSTRAINT uq_exit_attendance UNIQUE,
pass_token VARCHAR2(60) NOT NULL CONSTRAINT uq_exit_pass_token UNIQUE,
issued_at TIMESTAMP DEFAULT LOCALTIMESTAMP NOT NULL,
expiry_time TIMESTAMP NOT NULL,
pass_status VARCHAR2(12) DEFAULT 'ACTIVE' NOT NULL,
CONSTRAINT fk_pass_attendance FOREIGN KEY (attendance_id) REFERENCES NIGHT_ATTENDANCE(attendance_id),
CONSTRAINT ck_pass_status CHECK (pass_status IN ('ACTIVE', 'USED', 'EXPIRED', 'CANCELLED')),
CONSTRAINT ck_pass_expiry CHECK (expiry_time > issued_at)
);
CREATE TABLE HOSTEL_RETURN (
return_id NUMBER(10) CONSTRAINT pk_hostel_return PRIMARY KEY,
pass_id NUMBER(10) NOT NULL CONSTRAINT uq_return_pass UNIQUE,
hostel_id VARCHAR2(10) NOT NULL,
verified_by VARCHAR2(10) NOT NULL,
arrival_time TIMESTAMP DEFAULT LOCALTIMESTAMP NOT NULL,
verification_status VARCHAR2(10) DEFAULT 'VERIFIED' NOT NULL,
CONSTRAINT fk_return_pass FOREIGN KEY (pass_id) REFERENCES EXIT_PASS(pass_id),
CONSTRAINT fk_return_hostel FOREIGN KEY (hostel_id) REFERENCES HOSTEL(hostel_id),
CONSTRAINT fk_return_staff FOREIGN KEY (verified_by) REFERENCES STAFF(staff_id),
CONSTRAINT ck_return_status CHECK (verification_status IN ('VERIFIED', 'REJECTED'))
);
CREATE TABLE AUDIT_LOG (
log_id NUMBER(10) CONSTRAINT pk_audit_log PRIMARY KEY,
entity_type VARCHAR2(30) NOT NULL,
entity_id VARCHAR2(60) NOT NULL,
action_name VARCHAR2(40) NOT NULL,
performed_by VARCHAR2(10),
action_time TIMESTAMP DEFAULT LOCALTIMESTAMP NOT NULL,
details VARCHAR2(250),
CONSTRAINT fk_audit_staff FOREIGN KEY (performed_by) REFERENCES STAFF(staff_id)
);
CREATE SEQUENCE ATTENDANCE_SEQ START WITH 6001 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE LIBRARY_SESSION_SEQ START WITH 2001 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE INDEX IDX_ATTENDANCE_SESSION ON NIGHT_ATTENDANCE(session_id);
CREATE INDEX IDX_STUDENT_HOSTEL ON STUDENT(hostel_id);
CREATE INDEX IDX_AUDIT_TIME ON AUDIT_LOG(action_time);
CREATE SEQUENCE EXIT_PASS_SEQ START WITH 5001 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE HOSTEL_RETURN_SEQ START WITH 5001 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE AUDIT_LOG_SEQ START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE OR REPLACE TRIGGER TRG_EXIT_PASS_AUDIT
AFTER INSERT ON EXIT_PASS
FOR EACH ROW
BEGIN
INSERT INTO AUDIT_LOG (
log_id, entity_type, entity_id, action_name, performed_by, action_time, details
) VALUES (
AUDIT_LOG_SEQ.NEXTVAL,
'EXIT_PASS',
TO_CHAR(:NEW.pass_id),
'PASS_ISSUED',
'SYS001',
:NEW.issued_at,
'Exit pass created for attendance ID ' || TO_CHAR(:NEW.attendance_id)
);
END;
/
CREATE OR REPLACE TRIGGER TRG_HOSTEL_RETURN_STATE
AFTER INSERT ON HOSTEL_RETURN
FOR EACH ROW
WHEN (NEW.verification_status = 'VERIFIED')
BEGIN
UPDATE EXIT_PASS
SET pass_status = 'USED'
WHERE pass_id = :NEW.pass_id;
INSERT INTO AUDIT_LOG (
log_id, entity_type, entity_id, action_name, performed_by, action_time, details
) VALUES (
AUDIT_LOG_SEQ.NEXTVAL,
'HOSTEL_RETURN',
TO_CHAR(:NEW.return_id),
'RETURN_VERIFIED',
:NEW.verified_by,
:NEW.arrival_time,
'Verified pass ID ' || TO_CHAR(:NEW.pass_id) || ' at hostel ' || :NEW.hostel_id
);
END;
/
INSERT INTO STAFF VALUES ('SYS001','System audit actor','ADMIN',NULL,'system_audit_actor','N');
COMMIT;
CREATE OR REPLACE PROCEDURE PR_GENERATE_EXIT_PASS (
p_student_id IN STUDENT.student_id%TYPE,
p_session_id IN LIBRARY_SESSION.session_id%TYPE,
p_pass_token OUT EXIT_PASS.pass_token%TYPE,
p_event_time IN TIMESTAMP DEFAULT LOCALTIMESTAMP
) AS
v_attendance_id NIGHT_ATTENDANCE.attendance_id%TYPE;
v_deadline LIBRARY_SESSION.attendance_deadline%TYPE;
v_closing_time LIBRARY_SESSION.closing_time%TYPE;
v_session_status LIBRARY_SESSION.session_status%TYPE;
v_existing_pass NUMBER;
v_scan_time NIGHT_ATTENDANCE.scan_time%TYPE;
v_student_status STUDENT.student_status%TYPE;
v_hostel_status HOSTEL.hostel_status%TYPE;
BEGIN
SELECT attendance_deadline, closing_time, session_status
INTO v_deadline, v_closing_time, v_session_status
FROM LIBRARY_SESSION
WHERE session_id = p_session_id FOR UPDATE;
IF v_session_status <> 'OPEN' THEN
RAISE_APPLICATION_ERROR(-20001, 'The selected night-library session is not open.');
END IF;
IF p_event_time IS NULL OR p_event_time < v_deadline OR p_event_time >= v_closing_time THEN
RAISE_APPLICATION_ERROR(-20002, 'Exit pass can be generated only after attendance and before closing.');
END IF;
SELECT attendance_id
INTO v_attendance_id
FROM NIGHT_ATTENDANCE
WHERE student_id = p_student_id
AND session_id = p_session_id
AND attendance_status IN ('PRESENT', 'LATE') FOR UPDATE;
SELECT na.scan_time, st.student_status, h.hostel_status
INTO v_scan_time, v_student_status, v_hostel_status
FROM NIGHT_ATTENDANCE na JOIN STUDENT st ON st.student_id=na.student_id
JOIN HOSTEL h ON h.hostel_id=st.hostel_id
WHERE na.attendance_id=v_attendance_id;
IF v_student_status <> 'ACTIVE' OR v_hostel_status <> 'ACTIVE' THEN
RAISE_APPLICATION_ERROR(-20005, 'Student and assigned hostel must be active.');
END IF;
IF p_event_time < v_scan_time THEN
RAISE_APPLICATION_ERROR(-20006, 'Pass cannot precede the attendance scan.');
END IF;
SELECT COUNT(*)
INTO v_existing_pass
FROM EXIT_PASS
WHERE attendance_id = v_attendance_id;
IF v_existing_pass > 0 THEN
RAISE_APPLICATION_ERROR(-20003, 'An exit pass has already been issued for this attendance record.');
END IF;
p_pass_token := 'NLP-' || TO_CHAR(p_event_time, 'YYYYMMDD') || '-' || RAWTOHEX(SYS_GUID());
INSERT INTO EXIT_PASS (
pass_id, attendance_id, pass_token, issued_at, expiry_time, pass_status
) VALUES (
EXIT_PASS_SEQ.NEXTVAL,
v_attendance_id,
p_pass_token,
p_event_time,
v_closing_time + NUMTODSINTERVAL(15, 'MINUTE'),
'ACTIVE'
);
EXCEPTION
WHEN DUP_VAL_ON_INDEX THEN
RAISE_APPLICATION_ERROR(-20003, 'A pass already exists for this attendance.');
WHEN NO_DATA_FOUND THEN
RAISE_APPLICATION_ERROR(-20004, 'Student attendance or library session was not found.');
END;
/
CREATE OR REPLACE PROCEDURE PR_VERIFY_HOSTEL_RETURN (
p_pass_token IN EXIT_PASS.pass_token%TYPE,
p_staff_id IN STAFF.staff_id%TYPE,
p_result OUT VARCHAR2,
p_verified_at IN TIMESTAMP DEFAULT LOCALTIMESTAMP
) AS
v_pass_id EXIT_PASS.pass_id%TYPE;
v_pass_status EXIT_PASS.pass_status%TYPE;
v_issued_at EXIT_PASS.issued_at%TYPE;
v_expiry_time EXIT_PASS.expiry_time%TYPE;
v_student_id STUDENT.student_id%TYPE;
v_student_hostel STUDENT.hostel_id%TYPE;
v_staff_role STAFF.staff_role%TYPE;
v_staff_hostel STAFF.hostel_id%TYPE;
v_staff_active STAFF.is_active%TYPE;
v_existing_return NUMBER;
BEGIN
SELECT ep.pass_id, ep.pass_status, ep.issued_at, ep.expiry_time,
na.student_id, st.hostel_id
INTO v_pass_id, v_pass_status, v_issued_at, v_expiry_time,
v_student_id, v_student_hostel
FROM EXIT_PASS ep
JOIN NIGHT_ATTENDANCE na ON na.attendance_id = ep.attendance_id
JOIN STUDENT st ON st.student_id = na.student_id
WHERE ep.pass_token = p_pass_token FOR UPDATE OF ep.pass_status;
SELECT staff_role, hostel_id, is_active
INTO v_staff_role, v_staff_hostel, v_staff_active
FROM STAFF
WHERE staff_id = p_staff_id;
IF v_staff_active <> 'Y' OR v_staff_role <> 'HOSTEL_STAFF' THEN
p_result := 'REJECTED: active hostel staff credentials are required.';
RETURN;
END IF;
IF v_staff_hostel IS NULL OR v_staff_hostel <> v_student_hostel THEN
p_result := 'REJECTED: this pass belongs to a different hostel.';
RETURN;
END IF;
IF p_verified_at IS NULL THEN
p_result := 'REJECTED: verification time is required.';
RETURN;
END IF;
IF v_pass_status <> 'ACTIVE' THEN
p_result := 'REJECTED: pass status is ' || v_pass_status || '.';
RETURN;
END IF;
IF p_verified_at < v_issued_at THEN
p_result := 'REJECTED: verification time precedes pass issuance.';
RETURN;
END IF;
IF p_verified_at > v_expiry_time THEN
UPDATE EXIT_PASS SET pass_status = 'EXPIRED' WHERE pass_id = v_pass_id;
p_result := 'REJECTED: pass has expired.';
RETURN;
END IF;
SELECT COUNT(*)
INTO v_existing_return
FROM HOSTEL_RETURN
WHERE pass_id = v_pass_id;
IF v_existing_return > 0 THEN
p_result := 'REJECTED: this pass has already been used.';
RETURN;
END IF;
INSERT INTO HOSTEL_RETURN (
return_id, pass_id, hostel_id, verified_by, arrival_time, verification_status
) VALUES (
HOSTEL_RETURN_SEQ.NEXTVAL,
v_pass_id,
v_student_hostel,
p_staff_id,
p_verified_at,
'VERIFIED'
);
p_result := 'VERIFIED: hostel return recorded for student ' || v_student_id || '.';
EXCEPTION
WHEN DUP_VAL_ON_INDEX THEN
p_result := 'REJECTED: this pass has already been used.';
WHEN NO_DATA_FOUND THEN
p_result := 'REJECTED: pass token or staff ID was not found.';
END;
/
CREATE OR REPLACE FUNCTION FN_CHECK_PASS_STATUS (
p_pass_token IN EXIT_PASS.pass_token%TYPE,
p_as_of IN TIMESTAMP DEFAULT LOCALTIMESTAMP
) RETURN VARCHAR2 AS
v_status EXIT_PASS.pass_status%TYPE;
v_expiry_time EXIT_PASS.expiry_time%TYPE;
BEGIN
SELECT pass_status, expiry_time
INTO v_status, v_expiry_time
FROM EXIT_PASS
WHERE pass_token = p_pass_token;
IF v_status = 'ACTIVE' AND p_as_of > v_expiry_time THEN
RETURN 'EXPIRED';
END IF;
RETURN v_status;
EXCEPTION
WHEN NO_DATA_FOUND THEN
RETURN 'INVALID';
END;
/
CREATE OR REPLACE FUNCTION FN_GET_STUDENT_RETURN_STATUS (
p_student_id IN STUDENT.student_id%TYPE,
p_session_id IN LIBRARY_SESSION.session_id%TYPE
) RETURN VARCHAR2 AS
v_attendance_id NIGHT_ATTENDANCE.attendance_id%TYPE;
v_att_status NIGHT_ATTENDANCE.attendance_status%TYPE;
v_pass_id EXIT_PASS.pass_id%TYPE;
v_pass_status EXIT_PASS.pass_status%TYPE;
v_arrival_time HOSTEL_RETURN.arrival_time%TYPE;
v_expiry_time EXIT_PASS.expiry_time%TYPE;
v_closing_time LIBRARY_SESSION.closing_time%TYPE;
BEGIN
BEGIN
SELECT attendance_id, attendance_status
INTO v_attendance_id, v_att_status
FROM NIGHT_ATTENDANCE
WHERE student_id = p_student_id
AND session_id = p_session_id;
EXCEPTION
WHEN NO_DATA_FOUND THEN
RETURN 'NOT_ATTENDED';
END;
IF v_att_status = 'ABSENT' THEN
RETURN 'ABSENT';
END IF;
BEGIN
SELECT ep.pass_id, ep.pass_status, hr.arrival_time, ls.closing_time, ep.expiry_time
INTO v_pass_id, v_pass_status, v_arrival_time, v_closing_time, v_expiry_time
FROM EXIT_PASS ep
JOIN LIBRARY_SESSION ls ON ls.session_id = p_session_id
LEFT JOIN HOSTEL_RETURN hr ON hr.pass_id = ep.pass_id AND hr.verification_status = 'VERIFIED'
WHERE ep.attendance_id = v_attendance_id;
IF v_arrival_time IS NOT NULL THEN
IF v_arrival_time > v_closing_time THEN
RETURN 'LATE_RETURN';
ELSE
RETURN 'RETURNED';
END IF;
ELSIF v_pass_status = 'CANCELLED' THEN
RETURN 'CANCELLED_PASS - RETURN PENDING';
ELSIF v_pass_status = 'EXPIRED' OR (v_pass_status = 'ACTIVE' AND LOCALTIMESTAMP > v_expiry_time) THEN
RETURN 'EXPIRED_PASS - RETURN PENDING';
ELSE
RETURN 'EXITED - RETURN PENDING';
END IF;
EXCEPTION
WHEN NO_DATA_FOUND THEN
RETURN v_att_status;
END;
END;
/
-- Explicit cursor: processes every attendee for a session who has no verified return.
CREATE OR REPLACE PROCEDURE PR_GENERATE_UNRETURNED_REPORT (
p_session_id IN LIBRARY_SESSION.session_id%TYPE
) AS
CURSOR c_unreturned IS
SELECT st.student_id,
st.student_name,
h.hostel_name,
NVL(ep.pass_token, 'NO PASS ISSUED') AS pass_reference
FROM NIGHT_ATTENDANCE na
JOIN STUDENT st ON st.student_id = na.student_id
JOIN HOSTEL h ON h.hostel_id = st.hostel_id
LEFT JOIN EXIT_PASS ep ON ep.attendance_id = na.attendance_id
LEFT JOIN HOSTEL_RETURN hr ON hr.pass_id = ep.pass_id AND hr.verification_status = 'VERIFIED'
WHERE na.session_id = p_session_id
AND na.attendance_status IN ('PRESENT', 'LATE')
AND (ep.pass_id IS NULL OR hr.return_id IS NULL)
ORDER BY h.hostel_name, st.student_id;
v_count NUMBER := 0;
BEGIN
DBMS_OUTPUT.PUT_LINE('UNRETURNED STUDENT REPORT - SESSION ' || p_session_id);
DBMS_OUTPUT.PUT_LINE('Student ID | Student Name | Hostel | Pass Reference');
DBMS_OUTPUT.PUT_LINE('------------------------------------------------------');
FOR r IN c_unreturned LOOP
v_count := v_count + 1;
DBMS_OUTPUT.PUT_LINE(r.student_id || ' | ' || r.student_name || ' | ' || r.hostel_name || ' | ' || r.pass_reference);
END LOOP;
DBMS_OUTPUT.PUT_LINE('Total pending returns: ' || v_count);
END;
/
