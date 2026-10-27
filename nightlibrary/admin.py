from flask import abort,flash,g,redirect,render_template,request,url_for
from .db import connect
from .security import audit
from .service import RuleError

TABLES={'hostel':('hostel_id','hostel_status'),'student':('student_id','student_status'),'staff':('staff_id','is_active')}


def text(form,key,limit):
    value=form.get(key,'').strip()
    if not value or len(value)>limit:
        raise RuleError(f'{key} is required (maximum {limit} characters).')
    return value


def active_hostel(db,key):
    if not db.one("SELECT hostel_id FROM hostel WHERE hostel_id=:id AND hostel_status='ACTIVE'",dict(id=key)):
        raise RuleError('Choose an active hostel.')


def preserve_admin(db,record_id,role,active):
    if role!='ADMIN' or active!='Y':
        count=db.one("SELECT COUNT(*) n FROM staff WHERE staff_role='ADMIN' AND is_active='Y' AND staff_id<>:id",dict(id=record_id))['n']
        if count==0:
            raise RuleError('The last active administrator cannot be removed or demoted.')


def register_admin(app,roles):
    @app.route('/records/<kind>/<record_id>/edit',methods=['GET','POST'])
    @roles('ADMIN')
    def edit_record(kind,record_id):
        if kind not in TABLES:
            abort(404)
        pk,status_column=TABLES[kind]
        try:
            with connect(write=request.method=='POST') as db:
                if request.method=='POST':
                    # All administrative updates share a lock to protect last-admin and reassignment checks.
                    suffix=' FOR UPDATE' if db.oracle else ''
                    db.one("SELECT staff_id FROM staff WHERE staff_id='SYS001'"+suffix)
                row=db.one(f'SELECT * FROM {kind} WHERE {pk}=:id'+(' FOR UPDATE' if db.oracle and request.method=='POST' else ''),dict(id=record_id))
                if not row:
                    abort(404)
                hostels=db.rows('SELECT * FROM hostel ORDER BY hostel_id')
                if request.method=='POST':
                    f=request.form
                    status=f.get('status','')
                    if status not in (('Y','N') if kind=='staff' else ('ACTIVE','INACTIVE')):
                        raise RuleError('Choose a valid active state.')
                    name=text(f,'name',100 if kind=='hostel' else 80)
                    if kind=='hostel':
                        capacity=int(f['capacity'])
                        if not 1<=capacity<=99999 or f.get('hostel_type') not in ('MEN','WOMEN','OTHER'):
                            raise RuleError('Invalid hostel type or capacity.')
                        if status=='INACTIVE' and db.one("SELECT COUNT(*) n FROM student WHERE hostel_id=:id AND student_status='ACTIVE'",dict(id=record_id))['n']:
                            raise RuleError('Reassign or deactivate the hostel’s active students first.')
                        db.write('UPDATE hostel SET hostel_name=:name,hostel_type=:type,capacity=:capacity,hostel_status=:status WHERE hostel_id=:id',dict(name=name,type=f['hostel_type'],capacity=capacity,status=status,id=record_id))
                    elif kind=='student':
                        hostel=text(f,'hostel_id',10)
                        if status=='ACTIVE':
                            active_hostel(db,hostel)
                        if hostel!=row['hostel_id']:
                            pending=db.one('''SELECT COUNT(*) n FROM exit_pass p JOIN night_attendance a ON a.attendance_id=p.attendance_id
                              LEFT JOIN hostel_return r ON r.pass_id=p.pass_id AND r.verification_status='VERIFIED'
                              WHERE a.student_id=:id AND p.pass_status='ACTIVE' AND r.return_id IS NULL''',dict(id=record_id))['n']
                            if pending:
                                raise RuleError('Verify or cancel outstanding active passes before changing the hostel.')
                        year=int(f['year'])
                        if not 1<=year<=4:
                            raise RuleError('Year must be between 1 and 4.')
                        db.write('UPDATE student SET student_name=:name,program=:program,year_of_study=:year,hostel_id=:hostel,room_no=:room,student_status=:status WHERE student_id=:id',dict(name=name,program=text(f,'program',60),year=year,hostel=hostel,room=text(f,'room',20),status=status,id=record_id))
                    else:
                        role=f.get('role')
                        if role not in ('ADMIN','LIBRARY_STAFF','HOSTEL_STAFF'):
                            raise RuleError('Choose a valid staff role.')
                        if record_id==g.user['id'] and (role!='ADMIN' or status!='Y'):
                            raise RuleError('You cannot deactivate or demote your own administrator account.')
                        preserve_admin(db,record_id,role,status)
                        hostel=f.get('hostel_id') if role=='HOSTEL_STAFF' else None
                        if hostel:
                            active_hostel(db,hostel)
                        elif role=='HOSTEL_STAFF':
                            raise RuleError('Hostel staff require an assigned hostel.')
                        db.write('UPDATE staff SET staff_name=:name,staff_role=:role,hostel_id=:hostel,is_active=:status WHERE staff_id=:id',dict(name=name,role=role,hostel=hostel,status=status,id=record_id))
                    if kind in ('student','staff'):
                        db.write('UPDATE auth_account SET session_version=session_version+1 WHERE subject_kind=:kind AND subject_id=:id',dict(kind=kind,id=record_id))
                    audit(db,'RECORD_UPDATED',g.user['username'],kind,record_id,'Reference attributes updated; existing sessions invalidated where applicable')
            if request.method=='POST':
                flash('Record updated.','success')
                return redirect(url_for('records'))
        except (ValueError,KeyError) as exc:
            flash(str(exc),'error')
            with connect() as db:
                row=db.one(f'SELECT * FROM {kind} WHERE {pk}=:id',dict(id=record_id))
                hostels=db.rows('SELECT * FROM hostel ORDER BY hostel_id')
        return render_template('edit_record.html',kind=kind,row=row,hostels=hostels)

    @app.post('/records/<kind>/<record_id>/archive')
    @roles('ADMIN')
    def archive_record(kind,record_id):
        if kind not in TABLES:
            abort(404)
        pk,status_column=TABLES[kind]
        try:
            with connect(write=True) as db:
                suffix=' FOR UPDATE' if db.oracle else ''
                db.one("SELECT staff_id FROM staff WHERE staff_id='SYS001'"+suffix)
                row=db.one(f'SELECT * FROM {kind} WHERE {pk}=:id',dict(id=record_id))
                if not row:
                    abort(404)
                if kind=='staff':
                    if record_id==g.user['id']:
                        raise RuleError('You cannot archive your own administrator account.')
                    preserve_admin(db,record_id,row['staff_role'],'N')
                if kind=='hostel' and db.one("SELECT COUNT(*) n FROM student WHERE hostel_id=:id AND student_status='ACTIVE'",dict(id=record_id))['n']:
                    raise RuleError('Reassign or deactivate active students before archiving this hostel.')
                db.write(f'UPDATE {kind} SET {status_column}=:status WHERE {pk}=:id',dict(status='N' if kind=='staff' else 'INACTIVE',id=record_id))
                if kind in ('student','staff'):
                    db.write('UPDATE auth_account SET session_version=session_version+1 WHERE subject_kind=:kind AND subject_id=:id',dict(kind=kind,id=record_id))
                audit(db,'RECORD_ARCHIVED',g.user['username'],kind,record_id,'Soft deletion; transaction and audit history retained')
            flash('Record archived. Restore it using Edit when needed.','success')
        except ValueError as exc:
            flash(str(exc),'error')
        return redirect(url_for('records'))

    @app.post('/passes/<token>/cancel')
    @roles('ADMIN')
    def cancel_pass(token):
        reason=text(request.form,'reason',200)
        with connect(write=True) as db:
            lock=' FOR UPDATE' if db.oracle else ''
            p=db.one('SELECT pass_id,pass_status FROM exit_pass WHERE pass_token=:token'+lock,dict(token=token))
            if not p:
                abort(404)
            if p['pass_status'] not in ('ACTIVE','EXPIRED'):
                abort(409,description='Only an active or expired pass can be cancelled.')
            db.write("UPDATE exit_pass SET pass_status='CANCELLED' WHERE pass_id=:id",dict(id=p['pass_id']))
            audit(db,'PASS_CANCELLED',g.user['username'],'EXIT_PASS',p['pass_id'],reason)
        flash('Pass cancelled. No return has been recorded by this action.','success')
        return redirect(url_for('show_pass',token=token))

    @app.get('/security-events')
    @roles('ADMIN')
    def security_events():
        with connect() as db:
            limit=' FETCH FIRST 200 ROWS ONLY' if db.oracle else ' LIMIT 200'
            rows=db.rows('SELECT * FROM security_event ORDER BY event_id DESC'+limit)
        return render_template('security_events.html',rows=rows)
