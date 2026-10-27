import secrets
import time
from flask import current_app,session
from werkzeug.security import check_password_hash,generate_password_hash
from .db import connect,ROOT
from .security import digest,audit

DUMMY_HASH=generate_password_hash(secrets.token_urlsafe(32))


def migrate_local():
    if current_app.config['DATABASE_BACKEND']=='sqlite':
        with connect(write=True) as db:
            db.conn.executescript((ROOT/'sql/sqlite_hardening.sql').read_text())
            columns={r[1] for r in db.conn.execute('PRAGMA table_info(exit_pass)')}
            if 'issued_hostel_id' not in columns:
                db.write('ALTER TABLE exit_pass ADD COLUMN issued_hostel_id TEXT REFERENCES hostel(hostel_id)')
                db.write('''UPDATE exit_pass SET issued_hostel_id=(SELECT s.hostel_id FROM night_attendance a
                  JOIN student s ON s.student_id=a.student_id WHERE a.attendance_id=exit_pass.attendance_id)''')
            db.conn.executescript('''CREATE TRIGGER IF NOT EXISTS trg_pass_hostel_snapshot AFTER INSERT ON exit_pass
              WHEN NEW.issued_hostel_id IS NULL BEGIN
              UPDATE exit_pass SET issued_hostel_id=(SELECT s.hostel_id FROM night_attendance a JOIN student s
              ON s.student_id=a.student_id WHERE a.attendance_id=NEW.attendance_id) WHERE pass_id=NEW.pass_id; END;
              INSERT OR IGNORE INTO app_migration VALUES(2,datetime('now'));''')


def provision(db,username,kind,subject_id,password=None,issuer=None,sub=None):
    if kind not in ('student','staff') or not username.strip() or len(username)>80:
        raise ValueError('Invalid account identity.')
    if not db.one(f'SELECT {kind}_id FROM {kind} WHERE {kind}_id=:id',dict(id=subject_id)):
        raise ValueError('Create the student or staff record first.')
    if password is not None and not 14<=len(password)<=256:
        raise ValueError('Passwords must contain between 14 and 256 characters.')
    if (issuer is None)!=(sub is None) or (not password and not issuer):
        raise ValueError('Provide a password or an explicit OIDC issuer/subject binding.')
    db.write('''INSERT INTO auth_account(username,subject_kind,subject_id,password_hash,oidc_issuer,oidc_sub)
      VALUES(:username,:kind,:id,:hash,:issuer,:sub)''',dict(username=username.strip().lower(),kind=kind,id=subject_id,
      hash=generate_password_hash(password) if password else None,issuer=issuer,sub=sub))


def demo_account(db,username,kind,subject_id):
    """Development seed only. Production startup forbids all demo credentials."""
    if not current_app.config['DEMO_MODE'] or current_app.config['APP_ENV']=='production':
        return
    username=username.lower()
    if 'demo_password_hash' not in current_app.extensions:
        current_app.extensions['demo_password_hash']=generate_password_hash(current_app.config['DEMO_PASSWORD'])
    if not db.one('SELECT username FROM auth_account WHERE username=:u',dict(u=username)):
        db.write('''INSERT INTO auth_account(username,subject_kind,subject_id,password_hash)
          VALUES(:u,:kind,:id,:hash)''',dict(u=username,kind=kind,id=subject_id,hash=current_app.extensions['demo_password_hash']))


def seed_demo_accounts():
    if not current_app.config['DEMO_MODE'] or current_app.config['APP_ENV']=='production':
        return
    with connect(write=True) as db:
        for s in db.rows('SELECT student_id FROM student'):
            demo_account(db,s['student_id'],'student',s['student_id'])
        for s in db.rows('SELECT staff_id,username FROM staff'):
            demo_account(db,s['username'],'staff',s['staff_id'])


def authenticate(username,password):
    with connect() as db:
        account=db.one('SELECT * FROM auth_account WHERE username=:u',dict(u=username.strip().lower()))
    # Always pay the password-hash cost, including unknown and SSO-only accounts.
    good=check_password_hash(account['password_hash'] if account and account['password_hash'] else DUMMY_HASH,password)
    return account if good and account and account['enabled']=='Y' and subject_user(account) else None


def subject_user(account):
    kind=account['subject_kind']
    with connect() as db:
        if kind=='student':
            row=db.one("SELECT * FROM student WHERE student_id=:id AND student_status='ACTIVE'",dict(id=account['subject_id']))
            if row:
                return dict(id=row['student_id'],name=row['student_name'],role='STUDENT',hostel_id=row['hostel_id'],username=account['username'])
        else:
            row=db.one("SELECT * FROM staff WHERE staff_id=:id AND is_active='Y'",dict(id=account['subject_id']))
            if row:
                return dict(id=row['staff_id'],name=row['staff_name'],role=row['staff_role'],hostel_id=row['hostel_id'],username=account['username'])


def begin_session(account):
    revoke_session()
    session.clear()
    sid=secrets.token_urlsafe(32)
    epoch=int(time.time())
    with connect(write=True) as db:
        db.write('''INSERT INTO auth_session VALUES(:sid,:username,:version,:created,:seen,:expires)''',
            dict(sid=digest(sid),username=account['username'],version=account['session_version'],created=epoch,seen=epoch,expires=epoch+14400))
        audit(db,'LOGIN_SUCCESS',account['username'],'AUTH_ACCOUNT',account['username'])
    session['sid']=sid
    session['csrf']=secrets.token_hex(24)
    session.permanent=True


def current_user():
    sid=session.get('sid')
    if not sid:
        return None
    epoch=int(time.time())
    with connect() as db:
        account=db.one('''SELECT a.*,s.session_version AS login_version,s.expires_epoch,s.last_seen_epoch
            FROM auth_session s JOIN auth_account a ON a.username=s.username WHERE s.sid_hash=:sid''',dict(sid=digest(sid)))
    if not account or account['enabled']!='Y' or account['session_version']!=account['login_version'] or account['expires_epoch']<=epoch or epoch-account['last_seen_epoch']>current_app.config['SESSION_IDLE_SECONDS']:
        revoke_session()
        session.clear()
        return None
    user=subject_user(account)
    if not user:
        revoke_session()
        session.clear()
        return None
    if epoch-account['last_seen_epoch']>=60:
        with connect(write=True) as db:
            db.write('UPDATE auth_session SET last_seen_epoch=:time WHERE sid_hash=:sid',dict(time=epoch,sid=digest(sid)))
    return user


def revoke_session():
    if session.get('sid'):
        with connect(write=True) as db:
            db.write('DELETE FROM auth_session WHERE sid_hash=:sid',dict(sid=digest(session['sid'])))


def change_password(username,password):
    if not 14<=len(password)<=256:
        raise ValueError('Use a password with 14–256 characters.')
    with connect(write=True) as db:
        db.write('UPDATE auth_account SET password_hash=:hash,session_version=session_version+1 WHERE username=:u',dict(hash=generate_password_hash(password),u=username))
        db.write('DELETE FROM auth_session WHERE username=:u',dict(u=username))
        audit(db,'PASSWORD_CHANGED',username,'AUTH_ACCOUNT',username)
