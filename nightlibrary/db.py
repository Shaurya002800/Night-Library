from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo
import sqlite3
from flask import current_app

ROOT = Path(__file__).resolve().parent.parent

def now():
    return datetime.now(ZoneInfo('Asia/Kolkata')).replace(tzinfo=None, microsecond=0)

def stamp(value):
    return value.isoformat(sep=' ', timespec='seconds') if isinstance(value, datetime) else value

def dt(value):
    return value if isinstance(value, datetime) else datetime.fromisoformat(value)

class Database:
    def __init__(self, conn, oracle=False):
        self.conn, self.oracle = conn, oracle

    def execute(self, sql, params=None):
        cur = self.conn.cursor()
        params = params or {}
        if not self.oracle:
            params = {k: stamp(v) for k, v in params.items()}
        cur.execute(sql, params)
        return cur

    def rows(self, sql, params=None):
        cur = self.execute(sql, params)
        try:
            keys = [d[0].lower() for d in cur.description]
            return [dict(zip(keys, row)) for row in cur.fetchall()]
        finally:
            cur.close()

    def one(self, sql, params=None):
        rows = self.rows(sql, params)
        return rows[0] if rows else None

    def write(self, sql, params=None):
        cur = self.execute(sql, params)
        cur.close()

@contextmanager
def connect(write=False):
    oracle = current_app.config['DATABASE_BACKEND'] == 'oracle'
    if oracle:
        import oracledb
        cfg = current_app.config
        if not all(cfg.get(k) for k in ('DB_USER', 'DB_PASSWORD', 'DB_DSN')):
            raise RuntimeError('Oracle credentials are missing. Configure DB_USER, DB_PASSWORD and DB_DSN in .env.')
        conn = oracledb.connect(user=cfg['DB_USER'], password=cfg['DB_PASSWORD'], dsn=cfg['DB_DSN'])
        cur = conn.cursor()
        cur.execute("ALTER SESSION SET TIME_ZONE = '+05:30'")
        cur.close()
    else:
        path = Path(current_app.config['SQLITE_PATH'])
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(path, timeout=15)
        conn.execute('PRAGMA foreign_keys=ON')
        if write:
            conn.execute('BEGIN IMMEDIATE')
    try:
        yield Database(conn, oracle)
        if write:
            conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

def initialize():
    if current_app.config['DATABASE_BACKEND'] != 'sqlite':
        return
    with connect(write=True) as db:
        db.conn.executescript((ROOT / 'sql/sqlite_schema.sql').read_text())
        if db.one('SELECT COUNT(*) AS n FROM hostel')['n']:
            return
        hostels = ['MH-A','MH-B','MH-C','MH-D','MH-E','LH-A','LH-B','LH-C','LH-D','LH-E']
        for i, h in enumerate(hostels):
            db.write('INSERT INTO hostel VALUES(:id,:name,:type,:capacity,:status)',
                     dict(id=h,name=f'{"Men" if i<5 else "Women"} Hostel · Demo {h[-1]}',type='MEN' if i<5 else 'WOMEN',capacity=450+i*10,status='ACTIVE'))
            db.write('INSERT INTO staff VALUES(:id,:name,\'HOSTEL_STAFF\',:hostel,:username,\'Y\')',
                     dict(id=f'HST{i+1:03}',name=f'Hostel Staff Demo {i+1:02}',hostel=h,username=f'hostel_staff_{i+1:02}'))
        for staff_id,name,role,user in [('SYS001','System Administrator','ADMIN','sys_admin'),('LBR001','Library Staff Demo','LIBRARY_STAFF','library_staff_01')]:
            db.write('INSERT INTO staff VALUES(:id,:name,:role,NULL,:user,\'Y\')',dict(id=staff_id,name=name,role=role,user=user))
        for i in range(1,21):
            db.write('INSERT INTO student VALUES(:id,:name,\'B.Tech CSE\',2,:hostel,:room,\'ACTIVE\')',dict(id=f'24BCE{1000+i}',name=f'Demo Student {i:02}',hostel=hostels[(i-1)%10],room=f'{hostels[(i-1)%10][-1]}-{100+i}'))
        today=now().replace(hour=0,minute=0,second=0)
        for i in range(10):
            day=today-timedelta(days=9-i)
            db.write('INSERT INTO library_session VALUES(:id,:day,:start,:deadline,:close,:status)',dict(id=1001+i,day=day.date().isoformat(),start=day+timedelta(hours=21),deadline=day+timedelta(hours=21,minutes=30),close=day+timedelta(days=1),status='OPEN' if i==9 else 'CLOSED'))
        for i in range(1,11):
            sid=1000+min(i,9)
            sess=db.one('SELECT * FROM library_session WHERE session_id=:id',dict(id=sid))
            db.write('INSERT INTO night_attendance VALUES(:id,:student,:session,:scan,\'PRESENT\')',dict(id=2000+i,student=f'24BCE{1000+i}',session=sid,scan=sess['attendance_deadline']))
            close=dt(sess['closing_time'])
            db.write('INSERT INTO exit_pass VALUES(:id,:attendance,:token,:issue,:expiry,\'ACTIVE\')',dict(id=3000+i,attendance=2000+i,token=f'NLP-DEMO-{i:04}',issue=close-timedelta(minutes=12),expiry=close+timedelta(minutes=15)))
            db.write('INSERT INTO hostel_return VALUES(:id,:pass_id,:hostel,:staff,:arrival,\'VERIFIED\')',dict(id=4000+i,pass_id=3000+i,hostel=hostels[i-1],staff=f'HST{i:03}',arrival=close-timedelta(minutes=6)))
        for i in range(11,19):
            sess=db.one('SELECT * FROM library_session WHERE session_id=1010')
            db.write('INSERT INTO night_attendance VALUES(:id,:student,1010,:scan,:status)',dict(id=2000+i,student=f'24BCE{1000+i}',scan=sess['attendance_deadline'],status='LATE' if i==11 else 'PRESENT'))
        close=dt(sess['closing_time'])
        db.write("INSERT INTO exit_pass VALUES(3011,2011,'NLP-DEMO-EXPIRED',:issue,:expiry,'EXPIRED')",dict(issue=close-timedelta(minutes=12),expiry=close+timedelta(minutes=15)))
        db.write("INSERT INTO exit_pass VALUES(3012,2012,'NLP-DEMO-ACTIVE',:issue,:expiry,'ACTIVE')",dict(issue=close-timedelta(minutes=12),expiry=close+timedelta(minutes=15)))
