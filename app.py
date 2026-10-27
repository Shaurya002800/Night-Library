"""Local classroom prototype. Run: .venv/bin/python app.py"""
import csv
from datetime import datetime, timedelta
from functools import wraps
from io import BytesIO, StringIO
import os
from pathlib import Path
import secrets
import sqlite3
import time
import logging
from dotenv import load_dotenv
from flask import Flask, abort, flash, g, redirect, render_template, request, send_file, session, url_for, Response
import qrcode
from nightlibrary.db import ROOT, connect, dt, initialize, now
from nightlibrary.service import RuleError, attendance_rows, effective_status, event_time, issue_pass, pass_details, sessions, verify_pass

from nightlibrary.config import settings, validate
from nightlibrary.auth import (migrate_local,seed_demo_accounts,demo_account,authenticate,
    begin_session,current_user,revoke_session,change_password)
from nightlibrary.security import consume_limit,audit as security_audit,digest
load_dotenv()

def create_app(test_config=None):
    app=Flask(__name__)
    app.config.update(settings())
    if test_config:
        app.config.update(test_config)
    validate(app.config)
    app.config['SESSION_COOKIE_SECURE']=app.config['APP_ENV']=='production'
    if app.config['APP_ENV']=='production':
        app.config['DEBUG']=False
        app.logger.setLevel(logging.INFO)
    if app.config['PROXY_HOPS']:
        from werkzeug.middleware.proxy_fix import ProxyFix
        app.wsgi_app=ProxyFix(app.wsgi_app,x_for=1,x_proto=1,x_host=0,x_port=0,x_prefix=0)
    with app.app_context():
        if app.config['APP_ENV']!='production':
            initialize()
            migrate_local()
            seed_demo_accounts()
        else:
            with connect() as db:
                version=db.one('SELECT version FROM app_migration WHERE version=2')
                if not version or version['version']!=2:
                    raise RuntimeError('Apply the hardening database migration before starting production.')
                owner=(app.config.get('DB_SCHEMA') or app.config['DB_USER']).upper()
                units=db.one("SELECT COUNT(*) n FROM all_objects WHERE owner=:owner AND status='VALID' AND object_name IN ('PR_GENERATE_EXIT_PASS','PR_VERIFY_HOSTEL_RETURN','PR_GENERATE_UNRETURNED_REPORT','FN_CHECK_PASS_STATUS','FN_GET_STUDENT_RETURN_STATUS')",dict(owner=owner))
                if units['n']!=5:
                    raise RuntimeError('Required Oracle procedures/functions are missing or invalid.')
    from nightlibrary.cli import register_cli
    register_cli(app)
    from nightlibrary.integrations import register_integrations
    register_integrations(app)

    @app.template_filter('time')
    def time_format(value, fmt='%d %b, %I:%M %p'):
        return dt(value).strftime(fmt) if value else '—'

    def roles(*allowed):
        def decorator(fn):
            @wraps(fn)
            def wrapped(*args,**kwargs):
                if not g.user:
                    return redirect(url_for('login'))
                if allowed and g.user['role'] not in allowed:
                    abort(403)
                return fn(*args,**kwargs)
            return wrapped
        return decorator

    @app.before_request
    def prepare():
        g.user=None
        g.request_id=secrets.token_hex(12)
        g.request_started=time.monotonic()
        if request.endpoint=='static':
            return
        if app.config['APP_ENV']=='production' and not request.is_secure and request.endpoint not in ('health','readiness'):
            abort(400,description='HTTPS is required.')
        if request.endpoint=='attendance_webhook':
            return  # Independently authenticated by HMAC; browser cookies are ignored.
        g.user=current_user()
        if 'csrf' not in session:
            session['csrf']=secrets.token_hex(24)
        if request.method=='POST' and not secrets.compare_digest(session['csrf'],request.form.get('csrf','')):
            abort(400,description='The form expired. Reload the page and try again.')
        if request.endpoint=='verify' and request.method=='POST' and g.user:
            if not consume_limit('verify:'+g.user['username'],60,60):
                abort(429,description='Too many verification attempts. Try again in a minute.')

    @app.after_request
    def headers(response):
        response.headers['X-Content-Type-Options']='nosniff'
        response.headers['X-Frame-Options']='DENY'
        response.headers['Referrer-Policy']='no-referrer'
        response.headers['Content-Security-Policy']="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; media-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        response.headers['Permissions-Policy']='camera=(self), microphone=(), geolocation=()'
        response.headers['X-Request-ID']=getattr(g,'request_id','')
        if app.config['APP_ENV']=='production':
            response.headers['Strict-Transport-Security']='max-age=31536000'
        if request.endpoint!='static':
            app.logger.info('request id=%s endpoint=%s method=%s status=%s duration_ms=%d',
                getattr(g,'request_id',''),request.endpoint,request.method,response.status_code,
                int((time.monotonic()-getattr(g,'request_started',time.monotonic()))*1000))
        if request.endpoint!='static':
            response.headers['Cache-Control']='no-store'
        return response

    @app.context_processor
    def context():
        return dict(user=getattr(g,'user',None),csrf=session.get('csrf'),demo=app.config['DEMO_MODE'],backend=app.config['DATABASE_BACKEND'].upper(),auth_mode=app.config['AUTH_MODE'],production=app.config['APP_ENV']=='production')

    @app.errorhandler(400)
    @app.errorhandler(403)
    @app.errorhandler(404)
    def http_error(err):
        from werkzeug.exceptions import SecurityError
        if isinstance(err,SecurityError):
            return 'Invalid Host header.',400
        return render_template('error.html',code=err.code,message=err.description),err.code

    @app.errorhandler(RuleError)
    def rule_error(err):
        return render_template('error.html',code=400,message=str(err)),400

    @app.errorhandler(Exception)
    def unexpected(err):
        from werkzeug.exceptions import HTTPException
        if isinstance(err,HTTPException):
            return err
        app.logger.error('request_failed id=%s endpoint=%s error_type=%s',getattr(g,'request_id',''),request.endpoint,type(err).__name__)
        return render_template('error.html',code=503,message='The database operation could not be completed. Check your local database configuration and server log.'),503

    @app.route('/login',methods=['GET','POST'])
    def login():
        if request.method=='POST':
            if app.config['AUTH_MODE']=='oidc':
                abort(403,description='Use institutional sign-in.')
            name=request.form.get('username','').strip().lower()[:80]
            password=request.form.get('password','')
            if not consume_limit('login-ip:'+request.remote_addr,30) or not consume_limit('login-user:'+name,10):
                abort(429,description='Too many login attempts. Try again in 15 minutes.')
            account=authenticate(name,password) if len(password)<=256 else None
            if account:
                begin_session(account)
                return redirect(url_for('index'))
            with connect(write=True) as db:
                security_audit(db,'LOGIN_FAILED','anonymous','AUTH_ACCOUNT',digest(name),'Invalid credentials')
            flash('The username or password is incorrect.','error')
        return render_template('login.html')

    @app.post('/logout')
    def logout():
        revoke_session()
        session.clear()
        return redirect(url_for('login'))

    @app.route('/account/password',methods=['GET','POST'])
    @roles()
    def password():
        if app.config['AUTH_MODE']=='oidc':
            abort(403,description='Manage your password through your institutional provider.')
        if request.method=='POST':
            if not consume_limit('password:'+g.user['username'],5):
                abort(429)
            if not authenticate(g.user['username'],request.form.get('current_password','')):
                flash('Your current password is incorrect.','error')
            elif request.form.get('new_password')!=request.form.get('confirm_password'):
                flash('The new passwords do not match.','error')
            else:
                try:
                    change_password(g.user['username'],request.form.get('new_password',''))
                    session.clear()
                    flash('Password changed. Sign in again. All previous sessions were revoked.','success')
                    return redirect(url_for('login'))
                except ValueError as exc:
                    flash(str(exc),'error')
        return render_template('password.html')

    def selected(db):
        all_sessions=sessions(db)
        raw=request.args.get('session_id')
        try:
            sid=int(raw) if raw else (all_sessions[0]['session_id'] if all_sessions else None)
        except ValueError:
            abort(400,description='Invalid session number.')
        chosen=next((s for s in all_sessions if s['session_id']==sid),None)
        if sid is not None and not chosen:
            abort(404,description='Session not found.')
        return all_sessions,chosen

    @app.get('/')
    @roles()
    def index():
        if g.user['role']=='STUDENT':
            return redirect(url_for('student_passes'))
        with connect() as db:
            all_sessions,chosen=selected(db)
            rows=attendance_rows(db,chosen['session_id'],app.config['DEMO_MODE'],g.user['hostel_id'] if g.user['role']=='HOSTEL_STAFF' else None) if chosen else []
        eligible=[r for r in rows if r['attendance_status']!='ABSENT']
        counts=dict(attendance=len(eligible),passes=sum(bool(r['pass_token']) for r in eligible),returns=sum(bool(r['arrival_time']) for r in eligible),pending=sum(not r['arrival_time'] for r in eligible))
        return render_template('dashboard.html',sessions=all_sessions,chosen=chosen,rows=rows,counts=counts)

    @app.route('/passes/new',methods=['GET','POST'])
    @roles('STUDENT')
    def student_passes():
        if request.method=='POST':
            try:
                token=issue_pass(g.user['id'],int(request.form.get('session_id','')),app.config['DEMO_MODE'])
                flash('Your digital exit pass is ready.','success')
                return redirect(url_for('show_pass',token=token))
            except (RuleError,ValueError,sqlite3.IntegrityError) as err:
                flash(str(err),'error')
            except Exception as err:
                if 'ORA-20' in str(err) or 'ORA-00001' in str(err):
                    flash('Pass issuance rejected. Check attendance, session timing, and existing passes.','error')
                else:
                    raise
        with connect() as db:
            all_sessions=sessions(db)
            rows=[]
            for s in all_sessions:
                rows.extend(attendance_rows(db,s['session_id'],app.config['DEMO_MODE'],student=g.user['id']))
        return render_template('student.html',sessions=all_sessions,rows=rows)

    def authorized_pass(token):
        with connect() as db:
            p=pass_details(db,token)
        if not p:
            abort(404,description='Pass not found.')
        if g.user['role']=='STUDENT' and p['student_id']!=g.user['id']:
            abort(403)
        if g.user['role']=='HOSTEL_STAFF' and p['hostel_id']!=g.user['hostel_id']:
            abort(403)
        p['effective_status']=effective_status(p,(dt(p['issued_at'])+timedelta(minutes=6)) if app.config['DEMO_MODE'] else now())
        return p

    @app.get('/passes/<token>')
    @roles()
    def show_pass(token):
        return render_template('pass.html',p=authorized_pass(token))

    @app.get('/qr/<token>')
    @roles()
    def qr(token):
        authorized_pass(token)
        buffer=BytesIO()
        qrcode.make(token).save(buffer,format='PNG')
        buffer.seek(0)
        return send_file(buffer,mimetype='image/png',download_name='night-library-pass.png',as_attachment=request.args.get('download')=='1')

    @app.route('/verify',methods=['GET','POST'])
    @roles('HOSTEL_STAFF')
    def verify():
        result=None
        if request.method=='POST':
            token=request.form.get('pass_token','').strip()
            if not token or len(token)>60:
                flash('Enter a valid pass token, up to 60 characters.','error')
            else:
                ok,message=verify_pass(token,g.user['id'],app.config['DEMO_MODE'])
                result=dict(ok=ok,message=message)
        return render_template('verify.html',result=result)

    @app.route('/attendance',methods=['GET','POST'])
    @roles('ADMIN','LIBRARY_STAFF')
    def attendance():
        if request.method=='POST' and app.config['APP_ENV']=='production':
            abort(403,description='Production attendance must arrive through the approved integration endpoint.')
        if request.method=='POST':
            try:
                sid=int(request.form['session_id'])
                status=request.form.get('attendance_status','PRESENT')
                if status not in ('PRESENT','LATE','ABSENT'):
                    raise RuleError('Choose a valid attendance status.')
                with connect(write=True) as db:
                    lock=' FOR UPDATE' if db.oracle else ''
                    s=db.one('SELECT * FROM library_session WHERE session_id=:id'+lock,dict(id=sid))
                    if not s or s['session_status']!='OPEN':
                        raise RuleError('Attendance requires an open session.')
                    student=db.one("SELECT * FROM student WHERE student_id=:id AND student_status='ACTIVE'",dict(id=request.form['student_id'].strip().upper()))
                    if not student:
                        raise RuleError('An active student record is required.')
                    scan=dt(s['attendance_deadline']) if app.config['DEMO_MODE'] else now()
                    if status=='LATE' and app.config['DEMO_MODE']:
                        scan+=timedelta(minutes=5)
                    if not dt(s['start_time'])<=scan<dt(s['closing_time']):
                        raise RuleError('Attendance can only be recorded during the session.')
                    if status!='ABSENT':
                        status='LATE' if scan>dt(s['attendance_deadline']) else 'PRESENT'
                    if db.one('SELECT attendance_id FROM night_attendance WHERE student_id=:student AND session_id=:sid',dict(student=student['student_id'],sid=sid)):
                        raise RuleError('Attendance is already recorded for this student and session.')
                    id_expr='ATTENDANCE_SEQ.NEXTVAL' if db.oracle else '(SELECT COALESCE(MAX(attendance_id),0)+1 FROM night_attendance)'
                    db.write(f'INSERT INTO night_attendance VALUES({id_expr},:student,:sid,:scan,:status)',dict(student=student['student_id'],sid=sid,scan=scan,status=status))
                    security_audit(db,'ATTENDANCE_MANUAL',g.user['username'],'NIGHT_ATTENDANCE',student['student_id'],f'Session {sid}; {status}')
                flash('Attendance recorded.','success')
                return redirect(url_for('attendance',session_id=sid))
            except (ValueError,KeyError,sqlite3.IntegrityError) as err:
                flash(str(err),'error')
        with connect() as db:
            all_sessions,chosen=selected(db)
            students=db.rows("SELECT * FROM student WHERE student_status='ACTIVE' ORDER BY student_id")
            rows=attendance_rows(db,chosen['session_id'],app.config['DEMO_MODE']) if chosen else []
        return render_template('attendance.html',sessions=all_sessions,chosen=chosen,students=students,rows=rows)

    @app.route('/sessions',methods=['GET','POST'])
    @roles('ADMIN','LIBRARY_STAFF')
    def manage_sessions():
        if request.method=='POST':
            try:
                with connect(write=True) as db:
                    if request.form.get('action')=='status':
                        status=request.form['status']
                        if status not in ('SCHEDULED','OPEN','CLOSED'):
                            raise RuleError('Invalid session status.')
                        sid=int(request.form['session_id'])
                        if not db.one('SELECT session_id FROM library_session WHERE session_id=:id',dict(id=sid)):
                            raise RuleError('Session not found.')
                        db.write('UPDATE library_session SET session_status=:status WHERE session_id=:id',dict(status=status,id=sid))
                    else:
                        start=datetime.fromisoformat(request.form['start_time'])
                        deadline=datetime.fromisoformat(request.form['attendance_deadline'])
                        close=datetime.fromisoformat(request.form['closing_time'])
                        if not start<deadline<close:
                            raise RuleError('Opening must precede attendance deadline, which must precede closing.')
                        if db.one('SELECT session_id FROM library_session WHERE session_date=:day',dict(day=start.replace(hour=0,minute=0,second=0) if db.oracle else start.date().isoformat())):
                            raise RuleError('A session already exists for this date.')
                        expr='LIBRARY_SESSION_SEQ.NEXTVAL' if db.oracle else '(SELECT COALESCE(MAX(session_id),1000)+1 FROM library_session)'
                        db.write(f"INSERT INTO library_session VALUES({expr},:day,:start,:deadline,:close,'SCHEDULED')",dict(day=start.replace(hour=0,minute=0,second=0) if db.oracle else start.date().isoformat(),start=start,deadline=deadline,close=close))
                    security_audit(db,'SESSION_UPDATED' if request.form.get('action')=='status' else 'SESSION_CREATED',g.user['username'],'LIBRARY_SESSION',request.form.get('session_id','new'))
                flash('Session saved.','success')
                return redirect(url_for('manage_sessions'))
            except (ValueError,KeyError,sqlite3.IntegrityError) as err:
                flash(str(err),'error')
        with connect() as db:
            all_sessions=sessions(db)
        return render_template('sessions.html',sessions=all_sessions)

    @app.get('/reports')
    @roles('ADMIN','LIBRARY_STAFF','HOSTEL_STAFF')
    def reports():
        with connect() as db:
            all_sessions,chosen=selected(db)
            rows=attendance_rows(db,chosen['session_id'],app.config['DEMO_MODE'],g.user['hostel_id'] if g.user['role']=='HOSTEL_STAFF' else None) if chosen else []
        pending=[r for r in rows if r['attendance_status']!='ABSENT' and not r['arrival_time']]
        if request.args.get('format')=='csv':
            out=StringIO()
            writer=csv.writer(out)
            writer.writerow(['Student ID','Student name','Hostel','Attendance','Pass status','Return status'])
            for r in pending:
                values=[r[k] for k in ('student_id','student_name','hostel_name','attendance_status','effective_status','return_status')]
                writer.writerow(["'"+str(v) if str(v).startswith(('=','+','-','@','\t','\r')) else v for v in values])
            return Response(out.getvalue(),mimetype='text/csv',headers={'Content-Disposition':'attachment; filename=pending-returns.csv'})
        return render_template('reports.html',sessions=all_sessions,chosen=chosen,rows=pending)

    @app.get('/audit')
    @roles('ADMIN')
    def audit():
        with connect() as db:
            suffix=' FETCH FIRST 200 ROWS ONLY' if db.oracle else ' LIMIT 200'
            rows=db.rows('''SELECT a.*,s.staff_name FROM audit_log a LEFT JOIN staff s ON s.staff_id=a.performed_by ORDER BY a.log_id DESC'''+suffix)
        return render_template('audit.html',rows=rows)

    @app.route('/records',methods=['GET','POST'])
    @roles('ADMIN')
    def records():
        if request.method=='POST':
            try:
                f=request.form
                kind=f['kind']
                required = {
                    'hostel': {'hostel_id':10,'name':100},
                    'student': {'student_id':12,'name':80,'program':60,'room':20},
                    'staff': {'staff_id':10,'name':80,'username':40},
                }
                if kind not in required:
                    raise RuleError('Unknown record type.')
                for field, maximum in required[kind].items():
                    if not f.get(field,'').strip() or len(f[field].strip()) > maximum:
                        raise RuleError('Check required fields and maximum field lengths.')
                with connect(write=True) as db:
                    if kind=='hostel':
                        capacity=int(f['capacity'])
                        if capacity<=0 or f['hostel_type'] not in ('MEN','WOMEN','OTHER'):
                            raise RuleError('Enter a valid capacity and hostel type.')
                        db.write("INSERT INTO hostel VALUES(:id,:name,:type,:capacity,'ACTIVE')",dict(id=f['hostel_id'].strip().upper(),name=f['name'].strip(),type=f['hostel_type'],capacity=capacity))
                    elif kind=='student':
                        year=int(f['year'])
                        if not 1<=year<=4:
                            raise RuleError('Year of study must be between 1 and 4.')
                        if not db.one("SELECT hostel_id FROM hostel WHERE hostel_id=:id AND hostel_status='ACTIVE'",dict(id=f['hostel_id'])):
                            raise RuleError('Choose an active hostel.')
                        db.write("INSERT INTO student VALUES(:id,:name,:program,:year,:hostel,:room,'ACTIVE')",dict(id=f['student_id'].strip().upper(),name=f['name'].strip(),program=f['program'].strip(),year=year,hostel=f['hostel_id'],room=f['room'].strip()))
                    elif kind=='staff':
                        role=f['role']
                        if role not in ('ADMIN','LIBRARY_STAFF','HOSTEL_STAFF'):
                            raise RuleError('Choose a valid staff role.')
                        db.write("INSERT INTO staff VALUES(:id,:name,:role,:hostel,:username,'Y')",dict(id=f['staff_id'].strip().upper(),name=f['name'].strip(),role=role,hostel=f['hostel_id'] if role=='HOSTEL_STAFF' else None,username=f['username'].strip()))
                    else:
                        raise RuleError('Unknown record type.')
                    if kind=='student':
                        demo_account(db,f['student_id'].strip(),'student',f['student_id'].strip().upper())
                    elif kind=='staff':
                        demo_account(db,f['username'].strip(),'staff',f['staff_id'].strip().upper())
                    security_audit(db,'RECORD_CREATED',g.user['username'],kind,f[kind+'_id'].strip().upper())
                flash('Reference record added.','success')
                return redirect(url_for('records'))
            except (ValueError,KeyError,sqlite3.IntegrityError) as err:
                flash('Could not add record. Check required fields, unique IDs and hostel assignment.','error')
        with connect() as db:
            hostels=db.rows('SELECT * FROM hostel ORDER BY hostel_id')
            students=db.rows('SELECT * FROM student ORDER BY student_id')
            staff=db.rows('SELECT * FROM staff ORDER BY staff_id')
        return render_template('records.html',hostels=hostels,students=students,staff=staff)

    from nightlibrary.admin import register_admin
    register_admin(app,roles)

    @app.get('/health')
    def health():
        return dict(status='ok')

    @app.get('/ready')
    def readiness():
        try:
            with connect() as db:
                version=db.one('SELECT version FROM app_migration WHERE version=2')
                if not version or version['version']!=2:
                    return dict(status='unavailable'),503
            return dict(status='ready')
        except Exception:
            return dict(status='unavailable'),503

    return app

if __name__=='__main__':
    create_app().run(host='127.0.0.1',port=int(os.getenv('PORT','5050')),debug=False)
