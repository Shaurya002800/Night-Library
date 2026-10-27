/*
VIT Night Library Digital Exit & Hostel Return Verification System
Database: Oracle Database (SQL/PLSQL)
IMPORTANT:
- Run this script in a dedicated development schema, preferably with SQL Developer > Run Script (F5).
- All student/staff/hostel data below are synthetic demonstration records, not official VIT records.
- The script creates the schema, PL/SQL components, and demonstration data.
- Do not run this in a production or shared schema.
If you need to reset a previous attempt, manually drop these objects in child-to-parent order:
DROP TABLE HOSTEL_RETURN CASCADE CONSTRAINTS PURGE;
DROP TABLE EXIT_PASS CASCADE CONSTRAINTS PURGE;
DROP TABLE NIGHT_ATTENDANCE CASCADE CONSTRAINTS PURGE;
DROP TABLE LIBRARY_SESSION CASCADE CONSTRAINTS PURGE;
DROP TABLE AUDIT_LOG CASCADE CONSTRAINTS PURGE;
DROP TABLE STAFF CASCADE CONSTRAINTS PURGE;
DROP TABLE STUDENT CASCADE CONSTRAINTS PURGE;
DROP TABLE HOSTEL CASCADE CONSTRAINTS PURGE;
DROP SEQUENCE EXIT_PASS_SEQ;
DROP SEQUENCE HOSTEL_RETURN_SEQ;
DROP SEQUENCE AUDIT_LOG_SEQ;
*/
SET SERVEROUTPUT ON;
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK;
ALTER SESSION SET TIME_ZONE = '+05:30';
PROMPT ============================================================
PROMPT 1. TABLES AND CONSTRAINTS
PROMPT ============================================================
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
PROMPT ============================================================
PROMPT 2. TRIGGERS
PROMPT ============================================================
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
PROMPT ============================================================
PROMPT 3. SAMPLE DATA - ALL RECORDS ARE SYNTHETIC
PROMPT ============================================================
INSERT INTO HOSTEL VALUES ('MH-A', 'Men Hostel - Demo A', 'MEN', 500, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('MH-B', 'Men Hostel - Demo B', 'MEN', 520, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('MH-C', 'Men Hostel - Demo C', 'MEN', 480, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('MH-D', 'Men Hostel - Demo D', 'MEN', 510, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('MH-E', 'Men Hostel - Demo E', 'MEN', 490, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('LH-A', 'Women Hostel - Demo A', 'WOMEN', 450, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('LH-B', 'Women Hostel - Demo B', 'WOMEN', 460, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('LH-C', 'Women Hostel - Demo C', 'WOMEN', 440, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('LH-D', 'Women Hostel - Demo D', 'WOMEN', 470, 'ACTIVE');
INSERT INTO HOSTEL VALUES ('LH-E', 'Women Hostel - Demo E', 'WOMEN', 455, 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1001', 'Demo Student 01', 'B.Tech IT', 2, 'MH-A', 'A-101', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1002', 'Demo Student 02', 'B.Tech CSE', 2, 'MH-B', 'B-102', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1003', 'Demo Student 03', 'B.Tech IT', 3, 'MH-C', 'C-103', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1004', 'Demo Student 04', 'B.Tech CSE', 2, 'MH-D', 'D-104', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1005', 'Demo Student 05', 'B.Tech ECE', 3, 'MH-E', 'E-105', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1006', 'Demo Student 06', 'B.Tech IT', 2, 'LH-A', 'A-106', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1007', 'Demo Student 07', 'B.Tech CSE', 3, 'LH-B', 'B-107', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1008', 'Demo Student 08', 'B.Tech IT', 2, 'LH-C', 'C-108', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1009', 'Demo Student 09', 'B.Tech ECE', 3, 'LH-D', 'D-109', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1010', 'Demo Student 10', 'B.Tech CSE', 2, 'LH-E', 'E-110', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1011', 'Demo Student 11', 'B.Tech IT', 2, 'MH-A', 'A-111', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1012', 'Demo Student 12', 'B.Tech CSE', 3, 'MH-B', 'B-112', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1013', 'Demo Student 13', 'B.Tech IT', 2, 'MH-C', 'C-113', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1014', 'Demo Student 14', 'B.Tech ECE', 3, 'MH-D', 'D-114', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1015', 'Demo Student 15', 'B.Tech CSE', 2, 'MH-E', 'E-115', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1016', 'Demo Student 16', 'B.Tech IT', 2, 'LH-A', 'A-116', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1017', 'Demo Student 17', 'B.Tech CSE', 3, 'LH-B', 'B-117', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1018', 'Demo Student 18', 'B.Tech IT', 2, 'LH-C', 'C-118', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1019', 'Demo Student 19', 'B.Tech ECE', 3, 'LH-D', 'D-119', 'ACTIVE');
INSERT INTO STUDENT VALUES ('24BCE1020', 'Demo Student 20', 'B.Tech CSE', 2, 'LH-E', 'E-120', 'ACTIVE');
INSERT INTO STAFF VALUES ('SYS001', 'System Administrator', 'ADMIN', NULL, 'sys_admin', 'Y');
INSERT INTO STAFF VALUES ('LBR001', 'Library Staff Demo', 'LIBRARY_STAFF', NULL, 'library_staff_01', 'Y');
INSERT INTO STAFF VALUES ('HST001', 'Hostel Staff Demo 01', 'HOSTEL_STAFF', 'MH-A', 'hostel_staff_01', 'Y');
INSERT INTO STAFF VALUES ('HST002', 'Hostel Staff Demo 02', 'HOSTEL_STAFF', 'MH-B', 'hostel_staff_02', 'Y');
INSERT INTO STAFF VALUES ('HST003', 'Hostel Staff Demo 03', 'HOSTEL_STAFF', 'MH-C', 'hostel_staff_03', 'Y');
INSERT INTO STAFF VALUES ('HST004', 'Hostel Staff Demo 04', 'HOSTEL_STAFF', 'MH-D', 'hostel_staff_04', 'Y');
INSERT INTO STAFF VALUES ('HST005', 'Hostel Staff Demo 05', 'HOSTEL_STAFF', 'MH-E', 'hostel_staff_05', 'Y');
INSERT INTO STAFF VALUES ('HST006', 'Hostel Staff Demo 06', 'HOSTEL_STAFF', 'LH-A', 'hostel_staff_06', 'Y');
INSERT INTO STAFF VALUES ('HST007', 'Hostel Staff Demo 07', 'HOSTEL_STAFF', 'LH-B', 'hostel_staff_07', 'Y');
INSERT INTO STAFF VALUES ('HST008', 'Hostel Staff Demo 08', 'HOSTEL_STAFF', 'LH-C', 'hostel_staff_08', 'Y');
INSERT INTO STAFF VALUES ('HST009', 'Hostel Staff Demo 09', 'HOSTEL_STAFF', 'LH-D', 'hostel_staff_09', 'Y');
INSERT INTO STAFF VALUES ('HST010', 'Hostel Staff Demo 10', 'HOSTEL_STAFF', 'LH-E', 'hostel_staff_10', 'Y');
DECLARE
v_date DATE;
v_start TIMESTAMP;
v_deadline TIMESTAMP;
v_close TIMESTAMP;
v_status VARCHAR2(12);
BEGIN
FOR i IN 0 .. 9 LOOP
v_date := TRUNC(CURRENT_DATE) - 9 + i;
v_start := CAST(v_date AS TIMESTAMP) + NUMTODSINTERVAL(21, 'HOUR');
v_deadline := v_start + NUMTODSINTERVAL(30, 'MINUTE');
v_close := CAST(v_date + 1 AS TIMESTAMP);
IF i = 9 THEN
v_status := 'OPEN';
ELSE
v_status := 'CLOSED';
END IF;
INSERT INTO LIBRARY_SESSION (
session_id, session_date, start_time, attendance_deadline, closing_time, session_status
) VALUES (
1001 + i, v_date, v_start, v_deadline, v_close, v_status
);
END LOOP;
END;
/
INSERT INTO NIGHT_ATTENDANCE VALUES (2001, '24BCE1001', 1001, CAST(TRUNC(CURRENT_DATE)-9 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2002, '24BCE1002', 1002, CAST(TRUNC(CURRENT_DATE)-8 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2003, '24BCE1003', 1003, CAST(TRUNC(CURRENT_DATE)-7 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2004, '24BCE1004', 1004, CAST(TRUNC(CURRENT_DATE)-6 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'LATE');
INSERT INTO NIGHT_ATTENDANCE VALUES (2005, '24BCE1005', 1005, CAST(TRUNC(CURRENT_DATE)-5 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2006, '24BCE1006', 1006, CAST(TRUNC(CURRENT_DATE)-4 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2007, '24BCE1007', 1007, CAST(TRUNC(CURRENT_DATE)-3 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2008, '24BCE1008', 1008, CAST(TRUNC(CURRENT_DATE)-2 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2009, '24BCE1009', 1009, CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2010, '24BCE1010', 1009, CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(21.55, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2011, '24BCE1011', 1009, CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(21.6, 'HOUR'), 'LATE');
INSERT INTO NIGHT_ATTENDANCE VALUES (2012, '24BCE1012', 1010, CAST(TRUNC(CURRENT_DATE) AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2013, '24BCE1013', 1010, CAST(TRUNC(CURRENT_DATE) AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2014, '24BCE1014', 1010, CAST(TRUNC(CURRENT_DATE) AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2015, '24BCE1015', 1010, CAST(TRUNC(CURRENT_DATE) AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2016, '24BCE1016', 1010, CAST(TRUNC(CURRENT_DATE) AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2017, '24BCE1017', 1010, CAST(TRUNC(CURRENT_DATE) AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
INSERT INTO NIGHT_ATTENDANCE VALUES (2018, '24BCE1018', 1010, CAST(TRUNC(CURRENT_DATE) AS TIMESTAMP) + NUMTODSINTERVAL(21.5, 'HOUR'), 'PRESENT');
-- Ten passes with matching successful hostel-return records.
INSERT INTO EXIT_PASS VALUES (3001, 2001, 'NLP-DEMO-0001', CAST(TRUNC(CURRENT_DATE)-9 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'),
CAST(TRUNC(CURRENT_DATE)-8 AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3002, 2002, 'NLP-DEMO-0002', CAST(TRUNC(CURRENT_DATE)-8 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'),
CAST(TRUNC(CURRENT_DATE)-7 AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3003, 2003, 'NLP-DEMO-0003', CAST(TRUNC(CURRENT_DATE)-7 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'),
CAST(TRUNC(CURRENT_DATE)-6 AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3004, 2004, 'NLP-DEMO-0004', CAST(TRUNC(CURRENT_DATE)-6 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'),
CAST(TRUNC(CURRENT_DATE)-5 AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3005, 2005, 'NLP-DEMO-0005', CAST(TRUNC(CURRENT_DATE)-5 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'),
CAST(TRUNC(CURRENT_DATE)-4 AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3006, 2006, 'NLP-DEMO-0006', CAST(TRUNC(CURRENT_DATE)-4 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'),
CAST(TRUNC(CURRENT_DATE)-3 AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3007, 2007, 'NLP-DEMO-0007', CAST(TRUNC(CURRENT_DATE)-3 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'),
CAST(TRUNC(CURRENT_DATE)-2 AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3008, 2008, 'NLP-DEMO-0008', CAST(TRUNC(CURRENT_DATE)-2 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'),
CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3009, 2009, 'NLP-DEMO-0009', CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'), CAST(TRUNC(CURRENT_DATE)
AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO EXIT_PASS VALUES (3010, 2010, 'NLP-DEMO-0010', CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'), CAST(TRUNC(CURRENT_DATE)
AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
-- An expired pass with no return, and an active pass with a pending return.
INSERT INTO EXIT_PASS VALUES (3011, 2011, 'NLP-DEMO-0011', CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'), CAST(TRUNC(CURRENT_DATE)
AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'EXPIRED');
INSERT INTO EXIT_PASS VALUES (3012, 2012, 'NLP-DEMO-0012', CAST(TRUNC(CURRENT_DATE) AS TIMESTAMP) + NUMTODSINTERVAL(23.8, 'HOUR'), CAST(TRUNC(CURRENT_DATE)+1
AS TIMESTAMP) + NUMTODSINTERVAL(0.25, 'HOUR'), 'ACTIVE');
INSERT INTO HOSTEL_RETURN VALUES (4001, 3001, 'MH-A', 'HST001', CAST(TRUNC(CURRENT_DATE)-9 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4002, 3002, 'MH-B', 'HST002', CAST(TRUNC(CURRENT_DATE)-8 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4003, 3003, 'MH-C', 'HST003', CAST(TRUNC(CURRENT_DATE)-7 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4004, 3004, 'MH-D', 'HST004', CAST(TRUNC(CURRENT_DATE)-6 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4005, 3005, 'MH-E', 'HST005', CAST(TRUNC(CURRENT_DATE)-5 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4006, 3006, 'LH-A', 'HST006', CAST(TRUNC(CURRENT_DATE)-4 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4007, 3007, 'LH-B', 'HST007', CAST(TRUNC(CURRENT_DATE)-3 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4008, 3008, 'LH-C', 'HST008', CAST(TRUNC(CURRENT_DATE)-2 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4009, 3009, 'LH-D', 'HST009', CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
INSERT INTO HOSTEL_RETURN VALUES (4010, 3010, 'LH-E', 'HST010', CAST(TRUNC(CURRENT_DATE)-1 AS TIMESTAMP) + NUMTODSINTERVAL(23.9, 'HOUR'), 'VERIFIED');
COMMIT;
PROMPT ============================================================
PROMPT 4. PROCEDURES AND FUNCTIONS
PROMPT ============================================================
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
PROMPT ============================================================
PROMPT 5. DML DEMONSTRATION - INSERT, UPDATE, DELETE
PROMPT ============================================================
INSERT INTO HOSTEL (hostel_id, hostel_name, hostel_type, capacity, hostel_status)
VALUES ('DEMO-H', 'Temporary DML Demonstration Hostel', 'OTHER', 10, 'ACTIVE');
UPDATE HOSTEL
SET capacity = 12
WHERE hostel_id = 'DEMO-H';
DELETE FROM HOSTEL
WHERE hostel_id = 'DEMO-H';
COMMIT;
PROMPT ============================================================
PROMPT 6. 20 SQL QUERIES FOR REVIEW II
PROMPT ============================================================
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
PROMPT ============================================================
PROMPT 7. PL/SQL FUNCTION EXAMPLES
PROMPT ============================================================
SELECT FN_CHECK_PASS_STATUS('NLP-DEMO-0001') AS pass_1_status FROM DUAL;
SELECT FN_GET_STUDENT_RETURN_STATUS('24BCE1012', 1010) AS student_return_status FROM DUAL;
PROMPT ============================================================
PROMPT 8. CURSOR PROCEDURE EXAMPLE
PROMPT ============================================================
BEGIN
PR_GENERATE_UNRETURNED_REPORT(1010);
END;
/
PROMPT ============================================================
PROMPT 9. RECORD COUNTS - VERIFY 10+ RECORDS PER TABLE
PROMPT ============================================================
SELECT 'HOSTEL' AS table_name, COUNT(*) AS record_count FROM HOSTEL
UNION ALL SELECT 'STUDENT', COUNT(*) FROM STUDENT
UNION ALL SELECT 'STAFF', COUNT(*) FROM STAFF
UNION ALL SELECT 'LIBRARY_SESSION', COUNT(*) FROM LIBRARY_SESSION
UNION ALL SELECT 'NIGHT_ATTENDANCE', COUNT(*) FROM NIGHT_ATTENDANCE
UNION ALL SELECT 'EXIT_PASS', COUNT(*) FROM EXIT_PASS
UNION ALL SELECT 'HOSTEL_RETURN', COUNT(*) FROM HOSTEL_RETURN
UNION ALL SELECT 'AUDIT_LOG', COUNT(*) FROM AUDIT_LOG;
COMMIT;
PROMPT Review II schema setup and demo queries completed.
