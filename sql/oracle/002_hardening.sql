-- Apply once to an existing core schema with the schema OWNER, before deploying the app.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK;
CREATE TABLE APP_MIGRATION(version NUMBER PRIMARY KEY,applied_at TIMESTAMP NOT NULL);
CREATE TABLE AUTH_ACCOUNT (
 username VARCHAR2(80) PRIMARY KEY,subject_kind VARCHAR2(10) NOT NULL CHECK(subject_kind IN ('student','staff')),
 subject_id VARCHAR2(12) NOT NULL,password_hash VARCHAR2(512),enabled CHAR(1) DEFAULT 'Y' NOT NULL CHECK(enabled IN ('Y','N')),
 session_version NUMBER DEFAULT 1 NOT NULL,oidc_issuer VARCHAR2(300),oidc_sub VARCHAR2(200),
 UNIQUE(subject_kind,subject_id),UNIQUE(oidc_issuer,oidc_sub));
CREATE TABLE AUTH_SESSION (
 sid_hash VARCHAR2(64) PRIMARY KEY,username VARCHAR2(80) NOT NULL REFERENCES AUTH_ACCOUNT(username) ON DELETE CASCADE,
 session_version NUMBER NOT NULL,created_epoch NUMBER NOT NULL,last_seen_epoch NUMBER NOT NULL,expires_epoch NUMBER NOT NULL);
CREATE INDEX IDX_AUTH_EXPIRY ON AUTH_SESSION(expires_epoch);
CREATE TABLE RATE_BUCKET(bucket_key VARCHAR2(64) PRIMARY KEY,window_start NUMBER NOT NULL,hits NUMBER NOT NULL);
CREATE TABLE SECURITY_EVENT (
 event_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,action_name VARCHAR2(40) NOT NULL,
 actor VARCHAR2(80) NOT NULL,record_type VARCHAR2(30) NOT NULL,record_id VARCHAR2(160) NOT NULL,
 event_time TIMESTAMP NOT NULL,details VARCHAR2(1000) NOT NULL);
CREATE TABLE ATTENDANCE_INGEST (
 event_key VARCHAR2(160) PRIMARY KEY,payload_hash VARCHAR2(64) NOT NULL,
 attendance_id NUMBER(10) NOT NULL REFERENCES NIGHT_ATTENDANCE(attendance_id),received_at TIMESTAMP NOT NULL);
INSERT INTO APP_MIGRATION VALUES(1,LOCALTIMESTAMP);
COMMIT;

ALTER TABLE EXIT_PASS ADD(issued_hostel_id VARCHAR2(10));
UPDATE EXIT_PASS p SET issued_hostel_id=(SELECT st.hostel_id FROM NIGHT_ATTENDANCE na JOIN STUDENT st
  ON st.student_id=na.student_id WHERE na.attendance_id=p.attendance_id);
ALTER TABLE EXIT_PASS MODIFY(issued_hostel_id NOT NULL);
ALTER TABLE EXIT_PASS ADD CONSTRAINT FK_PASS_ISSUED_HOSTEL FOREIGN KEY(issued_hostel_id) REFERENCES HOSTEL(hostel_id);
CREATE OR REPLACE TRIGGER TRG_PASS_HOSTEL_SNAPSHOT
BEFORE INSERT ON EXIT_PASS FOR EACH ROW
BEGIN
  SELECT st.hostel_id INTO :NEW.issued_hostel_id FROM NIGHT_ATTENDANCE na
    JOIN STUDENT st ON st.student_id=na.student_id WHERE na.attendance_id=:NEW.attendance_id
    FOR UPDATE OF st.hostel_id;
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
na.student_id, ep.issued_hostel_id
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
p_pass_token := 'NLP-' || TO_CHAR(p_event_time, 'YYYYMMDD') || '-' || RAWTOHEX(DBMS_CRYPTO.RANDOMBYTES(16));
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

DECLARE
  invalid_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO invalid_count FROM USER_OBJECTS
    WHERE object_type IN ('PROCEDURE','FUNCTION','TRIGGER') AND status <> 'VALID';
  IF invalid_count > 0 THEN
    RAISE_APPLICATION_ERROR(-20100,'Invalid PL/SQL objects: inspect USER_ERRORS. Migration 2 is not complete.');
  END IF;
END;
/

INSERT INTO APP_MIGRATION VALUES(2,LOCALTIMESTAMP);
COMMIT;
