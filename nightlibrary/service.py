from datetime import timedelta
import secrets
from .db import connect, dt, now

class RuleError(ValueError):
    pass


def sessions(db):
    return db.rows('SELECT * FROM library_session ORDER BY session_date DESC')


def event_time(session, demo):
    return dt(session['closing_time']) - timedelta(minutes=12) if demo else now()


def effective_status(row, as_of):
    if not row.get('pass_token'):
        return 'NO PASS'
    if row['pass_status'] == 'ACTIVE' and as_of > dt(row['expiry_time']):
        return 'EXPIRED'
    return row['pass_status']


def attendance_rows(db, session_id, demo, hostel=None):
    rows=db.rows('''SELECT a.*,s.student_name,s.hostel_id,s.room_no,h.hostel_name,
        p.pass_id,p.pass_token,p.pass_status,p.issued_at,p.expiry_time,
        r.arrival_time,r.verified_by,l.closing_time
        FROM night_attendance a JOIN student s ON s.student_id=a.student_id
        JOIN hostel h ON h.hostel_id=s.hostel_id
        JOIN library_session l ON l.session_id=a.session_id
        LEFT JOIN exit_pass p ON p.attendance_id=a.attendance_id
        LEFT JOIN hostel_return r ON r.pass_id=p.pass_id AND r.verification_status='VERIFIED'
        WHERE a.session_id=:sid ORDER BY s.student_id''',dict(sid=session_id))
    for r in rows:
        r['effective_status']=effective_status(r,event_time(r,demo))
        r['return_status']=('LATE RETURN' if dt(r['arrival_time'])>dt(r['closing_time']) else 'RETURNED') if r['arrival_time'] else ('ABSENT' if r['attendance_status']=='ABSENT' else ('IN LIBRARY' if not r['pass_token'] else r['effective_status']+' · RETURN PENDING'))
    return [r for r in rows if not hostel or r['hostel_id']==hostel]


def issue_pass(student_id, session_id, demo=False, at=None):
    with connect(write=True) as db:
        lock=' FOR UPDATE' if db.oracle else ''
        session=db.one('SELECT * FROM library_session WHERE session_id=:id'+lock,dict(id=session_id))
        if not session:
            raise RuleError('Night-library session was not found.')
        timestamp=at or event_time(session,demo)
        if db.oracle:
            cur=db.conn.cursor()
            try:
                token=cur.var(str,size=100)
                cur.callproc('PR_GENERATE_EXIT_PASS',[student_id,session_id,token,timestamp])
                return token.getvalue()
            finally:
                cur.close()
        if session['session_status']!='OPEN':
            raise RuleError('The selected session is not open.')
        if not dt(session['attendance_deadline'])<=timestamp<dt(session['closing_time']):
            raise RuleError('Passes can be issued only from the attendance deadline until session closing.')
        a=db.one('''SELECT a.*,s.student_status,h.hostel_status FROM night_attendance a
          JOIN student s ON s.student_id=a.student_id JOIN hostel h ON h.hostel_id=s.hostel_id
          WHERE a.student_id=:student AND a.session_id=:sid''',dict(student=student_id,sid=session_id))
        if not a or a['attendance_status'] not in ('PRESENT','LATE'):
            raise RuleError('A PRESENT or LATE attendance record is required.')
        if a['student_status']!='ACTIVE' or a['hostel_status']!='ACTIVE':
            raise RuleError('The student and assigned hostel must be active.')
        if timestamp<dt(a['scan_time']):
            raise RuleError('A pass cannot precede the recorded attendance scan.')
        if db.one('SELECT pass_id FROM exit_pass WHERE attendance_id=:id',dict(id=a['attendance_id'])):
            raise RuleError('An exit pass has already been issued for this attendance.')
        token='NLP-'+timestamp.strftime('%Y%m%d')+'-'+secrets.token_hex(16).upper()
        db.write('''INSERT INTO exit_pass(attendance_id,pass_token,issued_at,expiry_time,pass_status)
          VALUES(:aid,:token,:issued,:expiry,'ACTIVE')''',dict(aid=a['attendance_id'],token=token,issued=timestamp,expiry=dt(session['closing_time'])+timedelta(minutes=15)))
        return token


def verify_pass(token, staff_id, demo=False, at=None):
    with connect(write=True) as db:
        if db.oracle:
            p=db.one('SELECT issued_at FROM exit_pass WHERE pass_token=:token',dict(token=token))
            timestamp=at or (dt(p['issued_at'])+timedelta(minutes=6) if demo and p else now())
            cur=db.conn.cursor()
            try:
                result=cur.var(str,size=500)
                cur.callproc('PR_VERIFY_HOSTEL_RETURN',[token,staff_id,result,timestamp])
                message=result.getvalue()
                return message.startswith('VERIFIED:'),message
            finally:
                cur.close()
        p=db.one('''SELECT p.*,s.student_id,s.hostel_id FROM exit_pass p
          JOIN night_attendance a ON a.attendance_id=p.attendance_id
          JOIN student s ON s.student_id=a.student_id WHERE p.pass_token=:token''',dict(token=token))
        if not p:
            return False,'Unknown pass token. No return was recorded.'
        sf=db.one('SELECT * FROM staff WHERE staff_id=:id',dict(id=staff_id))
        if not sf or sf['is_active']!='Y' or sf['staff_role']!='HOSTEL_STAFF':
            return False,'An active hostel staff account is required.'
        if sf['hostel_id']!=p['hostel_id']:
            return False,'This pass belongs to a different hostel. No return was recorded.'
        if p['pass_status']!='ACTIVE':
            return False,f"Pass is {p['pass_status'].lower()}. It cannot be used again."
        timestamp=at or (dt(p['issued_at'])+timedelta(minutes=6) if demo else now())
        if timestamp<dt(p['issued_at']):
            return False,'Verification time precedes pass issuance.'
        if timestamp>dt(p['expiry_time']):
            db.write("UPDATE exit_pass SET pass_status='EXPIRED' WHERE pass_id=:id",dict(id=p['pass_id']))
            return False,'The pass has expired. No return was recorded.'
        if db.one('SELECT return_id FROM hostel_return WHERE pass_id=:id',dict(id=p['pass_id'])):
            return False,'This pass already has a return record.'
        db.write('''INSERT INTO hostel_return(pass_id,hostel_id,verified_by,arrival_time,verification_status)
          VALUES(:pid,:hostel,:staff,:arrival,'VERIFIED')''',dict(pid=p['pass_id'],hostel=p['hostel_id'],staff=staff_id,arrival=timestamp))
        return True,f"Hostel return verified for {p['student_id']}. The pass is now used."


def pass_details(db,token):
    return db.one('''SELECT p.*,s.student_id,s.student_name,s.hostel_id,s.room_no,h.hostel_name,
        a.session_id,l.closing_time,r.arrival_time,r.verified_by
        FROM exit_pass p JOIN night_attendance a ON a.attendance_id=p.attendance_id
        JOIN student s ON s.student_id=a.student_id JOIN hostel h ON h.hostel_id=s.hostel_id
        JOIN library_session l ON l.session_id=a.session_id
        LEFT JOIN hostel_return r ON r.pass_id=p.pass_id AND r.verification_status='VERIFIED'
        WHERE p.pass_token=:token''',dict(token=token))
