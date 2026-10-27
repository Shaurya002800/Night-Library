CREATE TABLE IF NOT EXISTS app_migration(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS auth_account (
 username TEXT PRIMARY KEY, subject_kind TEXT NOT NULL CHECK(subject_kind IN ('student','staff')),
 subject_id TEXT NOT NULL, password_hash TEXT, enabled TEXT NOT NULL DEFAULT 'Y' CHECK(enabled IN ('Y','N')),
 session_version INTEGER NOT NULL DEFAULT 1, oidc_issuer TEXT, oidc_sub TEXT,
 UNIQUE(subject_kind,subject_id),UNIQUE(oidc_issuer,oidc_sub));
CREATE TABLE IF NOT EXISTS auth_session (
 sid_hash TEXT PRIMARY KEY,username TEXT NOT NULL REFERENCES auth_account(username) ON DELETE CASCADE,
 session_version INTEGER NOT NULL,created_epoch INTEGER NOT NULL,last_seen_epoch INTEGER NOT NULL,expires_epoch INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_auth_expiry ON auth_session(expires_epoch);
CREATE TABLE IF NOT EXISTS rate_bucket (bucket_key TEXT PRIMARY KEY,window_start INTEGER NOT NULL,hits INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS security_event (
 event_id INTEGER PRIMARY KEY,action_name TEXT NOT NULL,actor TEXT NOT NULL,record_type TEXT NOT NULL,
 record_id TEXT NOT NULL,event_time TEXT NOT NULL,details TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS attendance_ingest (
 event_key TEXT PRIMARY KEY,payload_hash TEXT NOT NULL,attendance_id INTEGER NOT NULL REFERENCES night_attendance(attendance_id),received_at TEXT NOT NULL);
INSERT OR IGNORE INTO app_migration VALUES(1,datetime('now'));
