PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS hostel (
 hostel_id TEXT PRIMARY KEY, hostel_name TEXT NOT NULL UNIQUE,
 hostel_type TEXT NOT NULL CHECK(hostel_type IN ('MEN','WOMEN','OTHER')),
 capacity INTEGER NOT NULL CHECK(capacity>0),
 hostel_status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK(hostel_status IN ('ACTIVE','INACTIVE')));
CREATE TABLE IF NOT EXISTS student (
 student_id TEXT PRIMARY KEY, student_name TEXT NOT NULL, program TEXT NOT NULL,
 year_of_study INTEGER NOT NULL CHECK(year_of_study BETWEEN 1 AND 4),
 hostel_id TEXT NOT NULL REFERENCES hostel(hostel_id), room_no TEXT NOT NULL,
 student_status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK(student_status IN ('ACTIVE','INACTIVE')));
CREATE TABLE IF NOT EXISTS staff (
 staff_id TEXT PRIMARY KEY, staff_name TEXT NOT NULL,
 staff_role TEXT NOT NULL CHECK(staff_role IN ('ADMIN','LIBRARY_STAFF','HOSTEL_STAFF')),
 hostel_id TEXT REFERENCES hostel(hostel_id), username TEXT NOT NULL UNIQUE,
 is_active TEXT NOT NULL DEFAULT 'Y' CHECK(is_active IN ('Y','N')),
 CHECK(staff_role!='HOSTEL_STAFF' OR hostel_id IS NOT NULL));
CREATE TABLE IF NOT EXISTS library_session (
 session_id INTEGER PRIMARY KEY, session_date TEXT NOT NULL UNIQUE,
 start_time TEXT NOT NULL, attendance_deadline TEXT NOT NULL, closing_time TEXT NOT NULL,
 session_status TEXT NOT NULL CHECK(session_status IN ('SCHEDULED','OPEN','CLOSED')),
 CHECK(start_time<attendance_deadline AND attendance_deadline<closing_time));
CREATE TABLE IF NOT EXISTS night_attendance (
 attendance_id INTEGER PRIMARY KEY, student_id TEXT NOT NULL REFERENCES student(student_id),
 session_id INTEGER NOT NULL REFERENCES library_session(session_id), scan_time TEXT NOT NULL,
 attendance_status TEXT NOT NULL CHECK(attendance_status IN ('PRESENT','LATE','ABSENT')),
 UNIQUE(student_id,session_id));
CREATE TABLE IF NOT EXISTS exit_pass (
 pass_id INTEGER PRIMARY KEY, attendance_id INTEGER NOT NULL UNIQUE REFERENCES night_attendance(attendance_id),
 pass_token TEXT NOT NULL UNIQUE, issued_at TEXT NOT NULL, expiry_time TEXT NOT NULL,
 pass_status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK(pass_status IN ('ACTIVE','USED','EXPIRED','CANCELLED')),
 CHECK(expiry_time>issued_at));
CREATE TABLE IF NOT EXISTS hostel_return (
 return_id INTEGER PRIMARY KEY, pass_id INTEGER NOT NULL UNIQUE REFERENCES exit_pass(pass_id),
 hostel_id TEXT NOT NULL REFERENCES hostel(hostel_id), verified_by TEXT NOT NULL REFERENCES staff(staff_id),
 arrival_time TEXT NOT NULL, verification_status TEXT NOT NULL DEFAULT 'VERIFIED' CHECK(verification_status IN ('VERIFIED','REJECTED')));
CREATE TABLE IF NOT EXISTS audit_log (
 log_id INTEGER PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
 action_name TEXT NOT NULL, performed_by TEXT REFERENCES staff(staff_id), action_time TEXT NOT NULL, details TEXT);
CREATE INDEX IF NOT EXISTS idx_attendance_session ON night_attendance(session_id);
CREATE INDEX IF NOT EXISTS idx_student_hostel ON student(hostel_id);
CREATE INDEX IF NOT EXISTS idx_audit_time ON audit_log(action_time);
CREATE TRIGGER IF NOT EXISTS trg_exit_pass_audit AFTER INSERT ON exit_pass BEGIN
 INSERT INTO audit_log(entity_type,entity_id,action_name,performed_by,action_time,details)
 VALUES('EXIT_PASS',NEW.pass_id,'PASS_ISSUED','SYS001',NEW.issued_at,'Exit pass created for attendance '||NEW.attendance_id);
END;
CREATE TRIGGER IF NOT EXISTS trg_hostel_return_state AFTER INSERT ON hostel_return
 WHEN NEW.verification_status='VERIFIED' BEGIN
 UPDATE exit_pass SET pass_status='USED' WHERE pass_id=NEW.pass_id;
 INSERT INTO audit_log(entity_type,entity_id,action_name,performed_by,action_time,details)
 VALUES('HOSTEL_RETURN',NEW.return_id,'RETURN_VERIFIED',NEW.verified_by,NEW.arrival_time,'Verified pass '||NEW.pass_id||' at hostel '||NEW.hostel_id);
END;
