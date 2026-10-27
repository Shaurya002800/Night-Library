from io import BytesIO
from PIL import Image
from nightlibrary.db import connect
from nightlibrary.service import issue_pass


def test_login_and_csrf(client,login):
    assert client.get('/').status_code==302
    assert client.post('/login',data={'username':'sys_admin','password':'library-demo'}).status_code==400
    assert login('sys_admin').status_code==302
    assert client.get('/').status_code==200
    assert client.get('/?session_id=bogus').status_code==400
    assert client.get('/?session_id=999999').status_code==404


def test_staff_pages(client,login):
    login('sys_admin')
    for route in ['/','/attendance','/sessions','/reports','/reports?format=csv','/audit','/records']:
        assert client.get(route).status_code==200,route
    assert client.get('/verify').status_code==403
    assert client.get('/passes/new').status_code==403
    login('library_staff_01')
    assert client.get('/attendance').status_code==200
    assert client.get('/audit').status_code==403
    assert client.get('/records').status_code==403


def test_student_to_hostel_http(app,client,login,post):
    login('24BCE1013')
    assert client.get('/passes/new').status_code==200
    assert client.get('/reports').status_code==403
    assert client.get('/verify').status_code==403
    response=post('/passes/new',{'session_id':'1010','student_id':'24BCE1014'})
    assert b'Your library exit pass' in response.data
    with app.app_context(),connect() as db:
        p=db.one('SELECT p.*,a.student_id FROM exit_pass p JOIN night_attendance a ON a.attendance_id=p.attendance_id WHERE a.attendance_id=2013')
        assert p['student_id']=='24BCE1013'
    token=p['pass_token']
    qr=client.get('/qr/'+token)
    assert qr.status_code==200
    assert Image.open(BytesIO(qr.data)).format=='PNG'
    login('24BCE1014')
    assert client.get('/passes/'+token).status_code==403
    assert client.get('/qr/'+token).status_code==403
    login('hostel_staff_02')
    assert b'different hostel' in post('/verify',{'pass_token':token,'staff_id':'HST003'}).data
    assert client.get('/passes/'+token).status_code==403
    login('hostel_staff_03')
    assert b'Return verified' in post('/verify',{'pass_token':token,'staff_id':'HST002'}).data
    assert b'Verification declined' in post('/verify',{'pass_token':token}).data
    assert client.get('/audit').status_code==403
    assert b'24BCE1012' not in client.get('/reports').data


def test_attendance_and_session_management(app,client,login,post):
    login('library_staff_01')
    data={'student_id':'24BCE1019','session_id':'1010','attendance_status':'PRESENT'}
    assert b'Attendance recorded' in post('/attendance',data).data
    assert b'already recorded' in post('/attendance',data).data
    response=post('/sessions',{'start_time':'2027-02-01T21:00','attendance_deadline':'2027-02-01T21:30','closing_time':'2027-02-02T00:00'})
    assert b'Session saved' in response.data
    with app.app_context(),connect() as db:
        s=db.one("SELECT * FROM library_session WHERE session_date='2027-02-01'")
        assert s['session_status']=='SCHEDULED'
    response=post('/sessions',{'action':'status','session_id':str(s['session_id']),'status':'OPEN'})
    assert b'Session saved' in response.data
    assert b'Opening must precede' in post('/sessions',{'start_time':'2027-03-01T22:00','attendance_deadline':'2027-03-01T21:30','closing_time':'2027-03-02T00:00'}).data


def test_directory_and_session_identity_recheck(app,client,login,post):
    login('sys_admin')
    assert b'Reference record added' in post('/records',{'kind':'hostel','hostel_id':'TEST-H','name':'Test Hostel','hostel_type':'OTHER','capacity':'100'}).data
    assert b'Reference record added' in post('/records',{'kind':'student','student_id':'TEST001','name':'Test Student','program':'CSE','year':'2','hostel_id':'TEST-H','room':'101'}).data
    assert b'Reference record added' in post('/records',{'kind':'staff','staff_id':'TESTSTAFF','name':'Test Staff','role':'HOSTEL_STAFF','hostel_id':'TEST-H','username':'test_staff'}).data
    login('test_staff')
    assert client.get('/verify').status_code==200
    with app.app_context(),connect(write=True) as db:
        db.write("UPDATE staff SET is_active='N' WHERE staff_id='TESTSTAFF'")
    assert client.get('/verify').status_code==302


def test_csv_formula_escape(app,client,login):
    with app.app_context(),connect(write=True) as db:
        db.write("UPDATE student SET student_name='=HYPERLINK(bad)' WHERE student_id='24BCE1013'")
    login('sys_admin')
    response=client.get('/reports?format=csv')
    assert response.mimetype=='text/csv'
    assert b"'=HYPERLINK(bad)" in response.data


def test_demo_off_uses_server_clock(app,monkeypatch):
    import nightlibrary.service as service
    from nightlibrary.db import dt
    with app.app_context(),connect() as db:
        s=db.one('SELECT * FROM library_session WHERE session_id=1010')
    monkeypatch.setattr(service,'now',lambda:dt(s['attendance_deadline']))
    with app.app_context():
        assert service.issue_pass('24BCE1013',1010,demo=False)


def test_master_records_reject_blank_values(app,client,login,post):
    login('sys_admin')
    response=post('/records',{'kind':'hostel','hostel_id':'  ','name':'  ','hostel_type':'OTHER','capacity':'10'})
    assert b'Could not add record' in response.data
    with app.app_context(),connect() as db:
        assert db.one("SELECT COUNT(*) AS n FROM hostel WHERE hostel_id='' OR hostel_name=''")['n']==0
