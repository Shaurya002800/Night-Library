import hashlib
import hmac
import json
import time
from datetime import timedelta
from unittest.mock import Mock
import pytest
from app import create_app
from nightlibrary.auth import authenticate,provision,change_password
from nightlibrary.config import settings,validate
from nightlibrary.db import connect,now,dt
from nightlibrary.security import digest
from nightlibrary.service import issue_pass


def csrf(client):
    with client.session_transaction() as s:
        return s['csrf']


def test_password_hashes_and_individual_credentials(app):
    with app.app_context():
        with connect(write=True) as db:
            db.write("DELETE FROM auth_account WHERE subject_id='24BCE1020'")
            provision(db,'new-student','student','24BCE1020','specific-long-password')
        assert authenticate('new-student','library-demo') is None
        assert authenticate('new-student','specific-long-password')
        with connect() as db:
            a=db.one("SELECT * FROM auth_account WHERE username='new-student'")
        assert a['password_hash'].startswith('scrypt:')
        assert 'specific-long-password' not in a['password_hash']
        assert authenticate('does-not-exist','specific-long-password') is None
        with pytest.raises(ValueError):
            with connect(write=True) as db:
                provision(db,'short-password','student','24BCE1020','short')


def test_logout_revokes_stolen_cookie(app,client,login,post):
    login('sys_admin')
    cookie=client.get_cookie('session').value
    assert client.get('/audit').status_code==200
    post('/logout')
    stolen=app.test_client()
    stolen.set_cookie('session',cookie)
    assert stolen.get('/audit').status_code==302


def test_password_reset_revokes_sessions(app,client,login):
    login('sys_admin')
    with app.app_context():
        change_password('sys_admin','a-new-long-password')
        assert authenticate('sys_admin','library-demo') is None
        assert authenticate('sys_admin','a-new-long-password')
    assert client.get('/audit').status_code==302


def test_password_change_form(app,client,login,post):
    login('sys_admin')
    assert client.get('/account/password').status_code==200
    assert b'current password is incorrect' in post('/account/password',{'current_password':'wrong','new_password':'a-new-long-password','confirm_password':'a-new-long-password'}).data
    assert b'Password changed' in post('/account/password',{'current_password':'library-demo','new_password':'a-new-long-password','confirm_password':'a-new-long-password'}).data
    assert client.get('/audit').status_code==302

@pytest.mark.parametrize('expired',['absolute','idle'])
def test_expired_sessions(app,client,login,expired):
    login('sys_admin')
    with client.session_transaction() as s:
        sid=digest(s['sid'])
    with app.app_context(),connect(write=True) as db:
        column='expires_epoch' if expired=='absolute' else 'last_seen_epoch'
        value=int(time.time())-(1 if expired=='absolute' else 1900)
        db.write(f'UPDATE auth_session SET {column}=:time WHERE sid_hash=:sid',dict(time=value,sid=sid))
    assert client.get('/audit').status_code==302


def test_throttle_persists_across_clients(app):
    for i in range(11):
        client=app.test_client()
        client.get('/login')
        response=client.post('/login',data={'csrf':csrf(client),'username':'unknown','password':'wrong'})
        assert response.status_code==(429 if i==10 else 200)


def production_config():
    cfg=settings()
    cfg.update(APP_ENV='production',DATABASE_BACKEND='oracle',DEMO_MODE=False,DEMO_PASSWORD='',
        SECRET_KEY='a'*48,DB_USER='app',DB_PASSWORD='configured-test-password',DB_DSN='tcps://db:2484/FREEPDB1',
        PUBLIC_BASE_URL='https://library.example.edu',TRUSTED_HOSTS=['library.example.edu'],
        ATTENDANCE_WEBHOOK_SECRET='b'*48,AUTH_MODE='local',PROXY_HOPS=1)
    return cfg

@pytest.mark.parametrize('key,value',[('DEMO_MODE',True),('DEMO_PASSWORD','library-demo'),('SECRET_KEY','short'),
    ('DATABASE_BACKEND','sqlite'),('PUBLIC_BASE_URL','http://library.example.edu'),('TRUSTED_HOSTS',None),
    ('TRUSTED_HOSTS',['*']),('ATTENDANCE_WEBHOOK_SECRET','short'),('DB_PASSWORD',''),('DB_DSN','db:1521/FREEPDB1'),('DB_SCHEMA','OWNER;DROP TABLE STAFF')])
def test_production_rejects_unsafe_config(key,value):
    cfg=production_config();cfg[key]=value
    with pytest.raises(RuntimeError):
        validate(cfg)


def test_production_config_and_no_auto_seed(monkeypatch):
    cfg=production_config();validate(cfg)
    import app as app_module
    fake=Mock()
    fake.one.side_effect=lambda sql,*args: {'n':5} if 'all_objects' in sql else {'version':2}
    from contextlib import contextmanager
    @contextmanager
    def database(**kwargs):
        yield fake
    monkeypatch.setattr(app_module,'connect',database)
    initialize=Mock(side_effect=AssertionError('Production must never seed'))
    monkeypatch.setattr(app_module,'initialize',initialize)
    production=create_app(cfg)
    initialize.assert_not_called()
    c=production.test_client()
    assert c.get('/login',base_url='http://library.example.edu').status_code==400
    assert c.get('/login',base_url='https://evil.example').status_code==400
    r=c.get('/login',base_url='https://library.example.edu')
    assert r.status_code==200
    assert 'library-demo' not in r.get_data(as_text=True)
    assert 'Secure;' in r.headers['Set-Cookie']
    assert r.headers['Strict-Transport-Security']=='max-age=31536000'
    assert "script-src 'self'" in r.headers['Content-Security-Policy']


def delivery(client,app,data,secret=None,epoch=None):
    raw=json.dumps(data,separators=(',',':')).encode()
    epoch=str(int(time.time()) if epoch is None else epoch)
    signature=hmac.new((secret or app.config['ATTENDANCE_WEBHOOK_SECRET']).encode(),epoch.encode()+b'.'+raw,hashlib.sha256).hexdigest()
    return client.post('/api/v1/attendance',data=raw,content_type='application/json',headers={'X-Library-Timestamp':epoch,'X-Library-Signature':signature})

@pytest.fixture
def integration(app):
    app.config['ATTENDANCE_WEBHOOK_SECRET']='unique-webhook-secret-with-48-characters-or-more'
    with app.app_context(),connect(write=True) as db:
        current=now()
        db.write("UPDATE library_session SET start_time=:start,attendance_deadline=:deadline,closing_time=:closing WHERE session_id=1010",dict(start=current-timedelta(minutes=20),deadline=current-timedelta(minutes=10),closing=current+timedelta(minutes=20)))
    return {'event_id':'device-event-1','student_id':'24BCE1019','session_id':1010,'scan_time':now().isoformat()+'+05:30'}


def test_hmac_ingestion_and_idempotency(app,client,integration):
    assert delivery(client,app,integration).status_code==201
    repeated=delivery(client,app,integration)
    assert repeated.status_code==200
    assert repeated.json['status']=='already_recorded'
    changed={**integration,'student_id':'24BCE1020'}
    assert delivery(client,app,changed).status_code==409
    with app.app_context(),connect() as db:
        assert db.one('SELECT COUNT(*) n FROM attendance_ingest')['n']==1
        assert db.one("SELECT attendance_status FROM night_attendance WHERE student_id='24BCE1019'")['attendance_status']=='LATE'

@pytest.mark.parametrize('change,status',[('bad-signature',401),('old-delivery',401),('naive-scan',400),('missing-student',400),('future-scan',400),('closed-session',400),('old-scan',400),('different-event',409),('bad-types',400)])
def test_webhook_rejections(app,client,integration,change,status):
    data=dict(integration);extra={}
    if change=='bad-signature':extra['secret']='wrong'
    elif change=='old-delivery':extra['epoch']=int(time.time())-301
    elif change=='naive-scan':data['scan_time']=now().isoformat()
    elif change=='missing-student':data['student_id']='UNKNOWN'
    elif change=='future-scan':data['scan_time']=(now()+timedelta(minutes=2)).isoformat()+'+05:30'
    elif change=='old-scan':data['scan_time']=(now()-timedelta(hours=2)).isoformat()+'+05:30'
    elif change=='closed-session':data['session_id']=1009
    elif change=='different-event':data['student_id']='24BCE1013'
    elif change=='bad-types':data['scan_time']=123
    response=delivery(client,app,data,**extra)
    assert response.status_code==status,response.json
    with app.app_context(),connect() as db:
        assert db.one('SELECT COUNT(*) n FROM attendance_ingest')['n']==0


def test_webhook_disabled_without_secret(client):
    assert client.post('/api/v1/attendance',json={}).status_code==503


def test_admin_edit_archive_restore(app,client,login,post):
    login('sys_admin')
    assert client.get('/records/student/24BCE1019/edit').status_code==200
    updated=post('/records/student/24BCE1019/edit',dict(name='Updated Student',program='IT',year='3',room='D-301',hostel_id='MH-D',status='ACTIVE'))
    assert b'Record updated' in updated.data
    assert b'Record archived' in post('/records/student/24BCE1019/archive').data
    with app.app_context(),connect() as db:
        assert db.one("SELECT student_status FROM student WHERE student_id='24BCE1019'")['student_status']=='INACTIVE'
    restored=post('/records/student/24BCE1019/edit',dict(name='Updated Student',program='IT',year='3',room='D-301',hostel_id='MH-D',status='ACTIVE'))
    assert b'Record updated' in restored.data
    assert b'cannot archive your own' in post('/records/staff/SYS001/archive').data
    assert b'Reassign or deactivate' in post('/records/hostel/MH-A/archive').data
    assert client.get('/security-events').status_code==200


def test_hostel_reassignment_requires_pass_resolution(app,client,login,post):
    with app.app_context():
        token=issue_pass('24BCE1013',1010,True)
    login('sys_admin')
    data=dict(name='Demo Student 13',program='IT',year='2',room='A-1',hostel_id='MH-A',status='ACTIVE')
    assert b'Verify or cancel' in post('/records/student/24BCE1013/edit',data).data
    assert b'Pass cancelled' in post('/passes/'+token+'/cancel',{'reason':'Approved hostel reassignment'}).data
    assert b'Record updated' in post('/records/student/24BCE1013/edit',data).data


def test_archiving_revokes_account_session(app,client,login):
    login('hostel_staff_03')
    admin=app.test_client();admin.get('/login')
    admin.post('/login',data={'csrf':csrf(admin),'username':'sys_admin','password':'library-demo'})
    admin.post('/records/staff/HST003/archive',data={'csrf':csrf(admin)})
    assert client.get('/verify').status_code==302


def test_nonadmin_cannot_modify_records(client,login,post):
    login('hostel_staff_03')
    assert client.get('/records/student/24BCE1013/edit').status_code==403
    assert post('/records/student/24BCE1013/archive').status_code==403


def test_sql_runner_parses_deployment_schema():
    from scripts.verify_oracle import statements,ROOT
    sql=list(statements((ROOT/'sql/oracle/001_schema.sql').read_text()))
    assert sum(s.startswith('CREATE TABLE') for s in sql)==8
    assert sum(s.startswith('CREATE OR REPLACE PROCEDURE') for s in sql)==3
    assert sum(s.startswith('CREATE OR REPLACE FUNCTION') for s in sql)==2
    assert sum(s.startswith('CREATE OR REPLACE TRIGGER') for s in sql)==2
    assert all('Demo Student' not in s for s in sql)


def test_pass_retains_original_hostel_after_reassignment(app):
    from nightlibrary.service import verify_pass,pass_details
    with app.app_context():
        token=issue_pass('24BCE1013',1010,True)
        assert verify_pass(token,'HST003',True)[0]
        with connect(write=True) as db:
            db.write("UPDATE student SET hostel_id='MH-D' WHERE student_id='24BCE1013'")
        with connect() as db:
            p=pass_details(db,token)
            assert p['hostel_id']=='MH-C'


@pytest.mark.parametrize('case',['valid','unknown-subject','wrong-issuer','provider-error'])
def test_oidc_uses_explicit_subject_binding(app,monkeypatch,case):
    from authlib.integrations import flask_client
    issuer='https://id.example.edu'
    client=Mock()
    claims={'iss':issuer,'sub':'institution-subject-123','email':'sys_admin@example.edu'}
    if case=='unknown-subject':claims['sub']='unprovisioned'
    if case=='wrong-issuer':claims['iss']='https://attacker.example'
    if case=='provider-error':client.authorize_access_token.side_effect=ValueError('Invalid signature')
    else:client.authorize_access_token.return_value={'userinfo':claims}
    oauth=Mock();oauth.register.return_value=client
    monkeypatch.setattr(flask_client,'OAuth',lambda app:oauth)
    cfg=dict(app.config)
    cfg.update(AUTH_MODE='both',OIDC_ISSUER=issuer,OIDC_METADATA_URL=issuer+'/.well-known/openid-configuration',OIDC_CLIENT_ID='test-client',OIDC_CLIENT_SECRET='test-client-secret')
    sso_app=create_app(cfg)
    with sso_app.app_context(),connect(write=True) as db:
        db.write("UPDATE auth_account SET oidc_issuer=:issuer,oidc_sub=:sub WHERE username='sys_admin'",dict(issuer=issuer,sub='institution-subject-123'))
    browser=sso_app.test_client()
    response=browser.get('/auth/callback')
    assert response.status_code==(302 if case=='valid' else 403)
    if case=='valid':assert browser.get('/audit').status_code==200
    else:assert browser.get('/audit').status_code==302


def test_provision_cli_does_not_accept_password_arguments(app):
    runner=app.test_cli_runner()
    response=runner.invoke(args=['create-account','--help'])
    assert response.exit_code==0
    assert '--password' not in response.output
    response=runner.invoke(args=['create-account','--username','new-student','--kind','student','--subject-id','24BCE1020'],input='too-short\ntoo-short\n')
    assert response.exit_code!=0


def test_non_ascii_signature_is_controlled_rejection(app,client,integration):
    response=client.post('/api/v1/attendance',json=integration,headers={'X-Library-Timestamp':str(int(time.time())),'X-Library-Signature':'é'})
    assert response.status_code==401


def test_oracle_pool_reused_and_failed_transaction_rolled_back(app,monkeypatch):
    import oracledb
    from unittest.mock import Mock
    connection=Mock();pool=Mock();pool.acquire.return_value=connection
    factory=Mock(return_value=pool)
    monkeypatch.setattr(oracledb,'create_pool',factory)
    app.config.update(DATABASE_BACKEND='oracle',DB_USER='runtime',DB_PASSWORD='not-a-real-password',DB_DSN='tcps://oracle.example:2484/FREEPDB1',DB_SCHEMA='NIGHT_OWNER')
    with app.app_context():
        with pytest.raises(RuntimeError):
            with connect(write=True) as db:
                assert db.oracle
                raise RuntimeError('Interrupted transaction')
        with connect() as db:
            assert db.oracle
    assert factory.call_count==1
    assert factory.call_args.kwargs['ssl_server_dn_match'] is True
    assert pool.acquire.call_count==2
    connection.rollback.assert_called_once()
    assert connection.close.call_count==2
    assert connection.call_timeout==15000
