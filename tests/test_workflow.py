from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
import sqlite3
import pytest
from nightlibrary.db import connect,dt,initialize
from nightlibrary.service import RuleError,attendance_rows,effective_status,issue_pass,verify_pass


def state():
    with connect() as db:
        return [db.one(f'SELECT COUNT(*) AS n FROM {table}')['n'] for table in ['exit_pass','hostel_return','audit_log']]


def test_seed_integrity_and_non_destructive_init(app):
    with app.app_context():
        assert state()==[12,10,22]
        initialize()
        assert state()==[12,10,22]
        with connect() as db:
            assert db.one("SELECT COUNT(*) AS n FROM exit_pass WHERE pass_status='USED'")['n']==10
            assert db.conn.execute('PRAGMA foreign_key_check').fetchall()==[]


def test_complete_transaction_and_reuse(app):
    with app.app_context():
        token=issue_pass('24BCE1013',1010,True)
        assert state()==[13,10,23]
        assert not verify_pass(token,'HST002',True)[0]
        assert state()==[13,10,23]
        assert verify_pass(token,'HST003',True)[0]
        assert state()==[13,11,24]
        assert not verify_pass(token,'HST003',True)[0]
        assert state()==[13,11,24]
        with connect() as db:
            assert db.one('SELECT pass_status FROM exit_pass WHERE pass_token=:t',dict(t=token))['pass_status']=='USED'

@pytest.mark.parametrize('student,sid',[('24BCE1013',1009),('UNKNOWN',1010),('24BCE1020',1010),('24BCE1012',1010)])
def test_issue_rejections(app,student,sid):
    with app.app_context():
        before=state()
        with pytest.raises(RuleError):
            issue_pass(student,sid,True)
        assert state()==before

@pytest.mark.parametrize('status',['ABSENT','INACTIVE','HOSTEL_INACTIVE'])
def test_ineligible_students(app,status):
    with app.app_context():
        with connect(write=True) as db:
            if status=='ABSENT':
                db.write("UPDATE night_attendance SET attendance_status='ABSENT' WHERE attendance_id=2013")
            elif status=='INACTIVE':
                db.write("UPDATE student SET student_status='INACTIVE' WHERE student_id='24BCE1013'")
            else:
                db.write("UPDATE hostel SET hostel_status='INACTIVE' WHERE hostel_id='MH-C'")
        with pytest.raises(RuleError):
            issue_pass('24BCE1013',1010,True)


def test_issue_time_boundaries(app):
    with app.app_context():
        with connect() as db:
            s=db.one('SELECT * FROM library_session WHERE session_id=1010')
        for timestamp in [dt(s['attendance_deadline'])-timedelta(seconds=1),dt(s['closing_time'])]:
            with pytest.raises(RuleError):
                issue_pass('24BCE1013',1010,at=timestamp)
        assert issue_pass('24BCE1013',1010,at=dt(s['attendance_deadline']))


def test_cannot_issue_before_scan(app):
    with app.app_context():
        with connect(write=True) as db:
            s=db.one('SELECT * FROM library_session WHERE session_id=1010')
            db.write('UPDATE night_attendance SET scan_time=:scan WHERE attendance_id=2013',dict(scan=dt(s['closing_time'])-timedelta(minutes=1)))
        with pytest.raises(RuleError,match='precede'):
            issue_pass('24BCE1013',1010,True)

@pytest.mark.parametrize('staff',['SYS001','LBR001','MISSING','HST002'])
def test_staff_authorization(app,staff):
    with app.app_context():
        token=issue_pass('24BCE1013',1010,True)
        assert not verify_pass(token,staff,True)[0]
        assert state()==[13,10,23]


def test_inactive_staff(app):
    with app.app_context():
        token=issue_pass('24BCE1013',1010,True)
        with connect(write=True) as db:
            db.write("UPDATE staff SET is_active='N' WHERE staff_id='HST003'")
        assert not verify_pass(token,'HST003',True)[0]


def test_expiry_and_verification_boundaries(app):
    with app.app_context():
        token=issue_pass('24BCE1013',1010,True)
        with connect() as db:
            p=db.one('SELECT * FROM exit_pass WHERE pass_token=:t',dict(t=token))
        assert not verify_pass(token,'HST003',at=dt(p['issued_at'])-timedelta(seconds=1))[0]
        assert verify_pass(token,'HST003',at=dt(p['expiry_time']))[0]
        token2=issue_pass('24BCE1014',1010,True)
        assert not verify_pass(token2,'HST004',at=dt(p['expiry_time'])+timedelta(seconds=1))[0]
        with connect() as db:
            assert db.one('SELECT pass_status FROM exit_pass WHERE pass_token=:t',dict(t=token2))['pass_status']=='EXPIRED'


def test_cancelled_and_unknown(app):
    with app.app_context():
        assert not verify_pass('MISSING','HST003',True)[0]
        token=issue_pass('24BCE1013',1010,True)
        with connect(write=True) as db:
            db.write("UPDATE exit_pass SET pass_status='CANCELLED' WHERE pass_token=:t",dict(t=token))
        assert not verify_pass(token,'HST003',True)[0]
        with connect() as db:
            rows=attendance_rows(db,1010,True)
        r=next(r for r in rows if r['student_id']=='24BCE1013')
        assert r['effective_status']=='CANCELLED'
        assert 'RETURN PENDING' in r['return_status']


def test_pending_includes_no_pass_but_not_absent(app):
    with app.app_context():
        with connect(write=True) as db:
            db.write("UPDATE night_attendance SET attendance_status='ABSENT' WHERE attendance_id=2018")
        with connect() as db:
            rows=attendance_rows(db,1010,True)
        pending=[r for r in rows if not r['arrival_time'] and r['attendance_status']!='ABSENT']
        assert len(pending)==7
        assert any(not r['pass_token'] for r in pending)
        assert all(r['student_id']!='24BCE1018' for r in pending)


def test_trigger_rollback_is_atomic(app):
    with app.app_context():
        token=issue_pass('24BCE1013',1010,True)
        before=state()
        with pytest.raises(RuntimeError):
            with connect(write=True) as db:
                p=db.one('SELECT * FROM exit_pass WHERE pass_token=:t',dict(t=token))
                db.write("INSERT INTO hostel_return(pass_id,hostel_id,verified_by,arrival_time) VALUES(:id,'MH-C','HST003',:time)",dict(id=p['pass_id'],time=dt(p['issued_at'])+timedelta(minutes=6)))
                assert db.one('SELECT pass_status FROM exit_pass WHERE pass_id=:id',dict(id=p['pass_id']))['pass_status']=='USED'
                raise RuntimeError('Simulate interrupted caller before commit')
        assert state()==before
        with connect() as db:
            assert db.one('SELECT pass_status FROM exit_pass WHERE pass_token=:t',dict(t=token))['pass_status']=='ACTIVE'


def test_concurrent_issue_and_scan(app):
    def issue(_):
        with app.app_context():
            try:
                return issue_pass('24BCE1013',1010,True)
            except RuleError:
                return None
    with ThreadPoolExecutor(max_workers=2) as pool:
        tokens=list(pool.map(issue,range(2)))
    assert sum(t is not None for t in tokens)==1
    token=next(t for t in tokens if t)
    def scan(_):
        with app.app_context():
            return verify_pass(token,'HST003',True)[0]
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(scan,range(2)))
    assert sorted(results)==[False,True]
    with app.app_context():
        assert state()==[13,11,24]


def test_constraints(app):
    with app.app_context():
        with pytest.raises(sqlite3.IntegrityError):
            with connect(write=True) as db:
                db.write("INSERT INTO night_attendance VALUES(9000,'24BCE1013',1010,'2026-10-26 21:30:00','PRESENT')")
        with pytest.raises(sqlite3.IntegrityError):
            with connect(write=True) as db:
                db.write("INSERT INTO staff VALUES('BAD','Bad','HOSTEL_STAFF',NULL,'bad','Y')")
