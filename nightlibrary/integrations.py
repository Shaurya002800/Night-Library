"""Approved upstream attendance feed and explicit OIDC identity bindings."""
import hashlib
import hmac
import re
import time
from datetime import datetime,timedelta
from zoneinfo import ZoneInfo
from flask import abort,current_app,request,session,redirect,url_for
from .db import connect,now,dt
from .security import consume_limit,audit
from .auth import begin_session,subject_user


def register_integrations(app):
    if app.config['AUTH_MODE'] in ('oidc','both'):
        from authlib.integrations.flask_client import OAuth
        oauth=OAuth(app)
        client=oauth.register('campus',client_id=app.config['OIDC_CLIENT_ID'],
            client_secret=app.config['OIDC_CLIENT_SECRET'],server_metadata_url=app.config['OIDC_METADATA_URL'],
            client_kwargs={'scope':'openid profile','code_challenge_method':'S256','timeout':10})

        @app.get('/auth/sso')
        def sso_login():
            if not consume_limit('sso:'+request.remote_addr,30):
                abort(429)
            return client.authorize_redirect(app.config['PUBLIC_BASE_URL']+'/auth/callback',nonce=__import__('secrets').token_urlsafe(32))

        @app.get('/auth/callback')
        def sso_callback():
            try:
                token=client.authorize_access_token()
                claims=token.get('userinfo')
                if not claims or claims.get('iss')!=app.config['OIDC_ISSUER'] or not claims.get('sub'):
                    abort(403,description='Institutional identity could not be verified.')
                with connect() as db:
                    account=db.one("SELECT * FROM auth_account WHERE oidc_issuer=:issuer AND oidc_sub=:sub AND enabled='Y'",dict(issuer=claims['iss'],sub=claims['sub']))
                if not account or not subject_user(account):
                    abort(403,description='Your institutional identity has not been provisioned for this service.')
                begin_session(account)
                return redirect(url_for('index'))
            except Exception as exc:
                from werkzeug.exceptions import HTTPException
                if isinstance(exc,HTTPException):
                    raise
                # Do not log authorization codes or provider tokens.
                abort(403,description='Institutional sign-in failed. Start a new sign-in attempt.')

    @app.post('/api/v1/attendance')
    def attendance_webhook():
        secret=app.config['ATTENDANCE_WEBHOOK_SECRET']
        if len(secret)<32:
            return {'error':'Attendance integration is not configured.'},503
        if not consume_limit('ingest-ip:'+request.remote_addr,120,60):
            abort(429)
        timestamp=request.headers.get('X-Library-Timestamp','')
        signature=request.headers.get('X-Library-Signature','')
        if not re.fullmatch(r'[0-9a-f]{64}',signature):
            return {'error':'Invalid delivery signature.'},401
        if not timestamp.isdigit() or abs(int(time.time())-int(timestamp))>300:
            return {'error':'Invalid or stale delivery timestamp.'},401
        raw=request.get_data(cache=True)
        expected=hmac.new(secret.encode(),timestamp.encode()+b'.'+raw,hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected,signature):
            return {'error':'Invalid delivery signature.'},401
        data=request.get_json(silent=True)
        if not isinstance(data,dict) or set(data)!={'event_id','student_id','session_id','scan_time'}:
            return {'error':'Supply event_id, student_id, session_id and an ISO8601 scan_time with timezone.'},400
        try:
            if not isinstance(data['event_id'],str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,80}',data['event_id']):
                raise ValueError('Invalid event_id.')
            if type(data['session_id']) is not int or not isinstance(data['student_id'],str) or len(data['student_id'])>12:
                raise ValueError('Invalid student or session identifier.')
            scan=datetime.fromisoformat(data['scan_time'])
            if scan.tzinfo is None:
                raise ValueError('scan_time must include a timezone.')
            scan=scan.astimezone(ZoneInfo('Asia/Kolkata')).replace(tzinfo=None,microsecond=0)
            key=app.config['ATTENDANCE_PROVIDER']+':'+data['event_id']
            if len(key)>160:
                raise ValueError('Provider and event_id exceed the maximum length.')
            body_hash=hashlib.sha256(raw).hexdigest()
            with connect(write=True) as db:
                # Serialize all events for one session, including duplicate delivery races.
                lock=' FOR UPDATE' if db.oracle else ''
                s=db.one('SELECT * FROM library_session WHERE session_id=:id'+lock,dict(id=data['session_id']))
                previous=db.one('SELECT * FROM attendance_ingest WHERE event_key=:key',dict(key=key))
                if previous:
                    if previous['payload_hash']!=body_hash:
                        return {'error':'This event_id was already delivered with different content.'},409
                    return {'status':'already_recorded','attendance_id':previous['attendance_id']},200
                if not s or s['session_status']!='OPEN':
                    raise ValueError('Attendance requires a known open session.')
                if scan>now()+timedelta(seconds=60) or scan<now()-timedelta(seconds=app.config['ATTENDANCE_MAX_DELAY_SECONDS']):
                    raise ValueError('The scan timestamp falls outside the permitted delivery delay.')
                if not dt(s['start_time'])<=scan<dt(s['closing_time']):
                    raise ValueError('The scan is outside the session window.')
                student=data['student_id'].upper()
                active=db.one("SELECT st.student_id FROM student st JOIN hostel h ON h.hostel_id=st.hostel_id WHERE st.student_id=:id AND st.student_status='ACTIVE' AND h.hostel_status='ACTIVE'",dict(id=student))
                if not active:
                    raise ValueError('Student and assigned hostel must be active.')
                if db.one('SELECT attendance_id FROM night_attendance WHERE student_id=:student AND session_id=:sid',dict(student=student,sid=data['session_id'])):
                    return {'error':'Attendance already exists under a different event.'},409
                expr='ATTENDANCE_SEQ.NEXTVAL' if db.oracle else '(SELECT COALESCE(MAX(attendance_id),0)+1 FROM night_attendance)'
                db.write(f'INSERT INTO night_attendance VALUES({expr},:student,:sid,:scan,:status)',dict(student=student,sid=data['session_id'],scan=scan,status='LATE' if scan>dt(s['attendance_deadline']) else 'PRESENT'))
                aid=db.one('SELECT attendance_id FROM night_attendance WHERE student_id=:student AND session_id=:sid',dict(student=student,sid=data['session_id']))['attendance_id']
                db.write('INSERT INTO attendance_ingest VALUES(:key,:hash,:aid,:time)',dict(key=key,hash=body_hash,aid=aid,time=now()))
                audit(db,'ATTENDANCE_INGESTED',app.config['ATTENDANCE_PROVIDER'],'NIGHT_ATTENDANCE',aid)
            return {'status':'recorded','attendance_id':aid},201
        except (ValueError,TypeError) as exc:
            return {'error':str(exc)},400
