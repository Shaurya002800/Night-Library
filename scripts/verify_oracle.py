"""Real Oracle acceptance runner. Never uses SQLite or fabricates Oracle evidence.

Use a new dedicated test schema. --install creates schema objects without dropping anything.
Credentials are read from ORACLE_TEST_USER, ORACLE_TEST_PASSWORD, ORACLE_TEST_DSN.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime,timedelta
import json
import os
from pathlib import Path
import re
import secrets
import sys
from zoneinfo import ZoneInfo

ROOT=Path(__file__).resolve().parents[1]


def statements(text):
    text=re.sub(r'/\*.*?\*/','',text,flags=re.S)
    buffer=[]
    procedural=False
    for line in text.splitlines():
        stripped=line.strip()
        if not stripped or stripped.startswith('--') or re.match(r'^(SET |PROMPT |WHENEVER )',stripped,re.I):
            continue
        if not buffer:
            procedural=bool(re.match(r'^(CREATE OR REPLACE (PROCEDURE|FUNCTION|TRIGGER)|DECLARE\b|BEGIN\b)',stripped,re.I))
        if stripped=='/':
            if buffer:
                yield '\n'.join(buffer)
            buffer=[]
            procedural=False
        else:
            buffer.append(line)
            if not procedural and stripped.endswith(';'):
                yield '\n'.join(buffer).rstrip().rstrip(';')
                buffer=[]
    if buffer:
        raise ValueError('SQL script contains an unterminated statement.')


def run(args):
    import oracledb
    keys=['ORACLE_TEST_USER','ORACLE_TEST_PASSWORD','ORACLE_TEST_DSN']
    if not all(os.getenv(k) for k in keys):
        raise RuntimeError('Set ORACLE_TEST_USER, ORACLE_TEST_PASSWORD and ORACLE_TEST_DSN for a dedicated test schema.')
    def connection():
        conn=oracledb.connect(user=os.environ[keys[0]],password=os.environ[keys[1]],dsn=os.environ[keys[2]])
        conn.call_timeout=15000
        conn.cursor().execute("ALTER SESSION SET TIME_ZONE='+05:30'")
        return conn
    checks=[]
    def check(name,condition):
        if not condition:
            raise AssertionError(name)
        checks.append(name)
    with connection() as conn:
        cur=conn.cursor()
        if args.install:
            cur.execute('SELECT COUNT(*) FROM user_tables')
            if cur.fetchone()[0]:
                raise RuntimeError('--install requires an empty test schema. Existing data is never dropped.')
            for filename in ('001_schema.sql','002_hardening.sql'):
                for statement in statements((ROOT/'sql/oracle'/filename).read_text()):
                    cur.execute(statement)
            conn.commit()
        cur.execute("SELECT object_name,object_type FROM user_objects WHERE status='INVALID'")
        invalid=cur.fetchall()
        cur.execute('SELECT name,type,line,position,text FROM user_errors ORDER BY name,sequence')
        errors=cur.fetchall()
        if invalid or errors:
            raise RuntimeError(f'Oracle compilation failed: {invalid!r}; {errors!r}')
        check('Oracle objects compile with no USER_ERRORS',True)
        suffix=secrets.token_hex(2).upper()
        h1,h2='Q'+suffix+'A','Q'+suffix+'B'
        staff1,staff2='T'+suffix+'A','T'+suffix+'B'
        students=['Q'+suffix+str(i) for i in range(6)]
        for h in (h1,h2):
            cur.execute("INSERT INTO hostel VALUES(:id,:name,'OTHER',20,'ACTIVE')",dict(id=h,name='QA '+h))
        for sf,h in ((staff1,h1),(staff2,h2)):
            cur.execute("INSERT INTO staff VALUES(:id,:name,'HOSTEL_STAFF',:hostel,:username,'Y')",dict(id=sf,name='QA '+sf,hostel=h,username=sf.lower()))
        current=datetime.now(ZoneInfo('Asia/Kolkata')).replace(tzinfo=None,microsecond=0)
        start=current-timedelta(minutes=20)
        deadline=current-timedelta(minutes=10)
        close=current+timedelta(minutes=10)
        cur.execute('SELECT LIBRARY_SESSION_SEQ.NEXTVAL FROM dual')
        sid=cur.fetchone()[0]
        # This test schema must not contain another session on today's date.
        cur.execute("INSERT INTO library_session VALUES(:id,:day,:start,:deadline,:closing,'OPEN')",dict(id=sid,day=current.replace(hour=0,minute=0,second=0),start=start,deadline=deadline,closing=close))
        for student in students:
            cur.execute("INSERT INTO student VALUES(:id,:name,'QA',2,:hostel,'QA-1','ACTIVE')",dict(id=student,name='QA '+student,hostel=h1))
            cur.execute("INSERT INTO night_attendance VALUES(ATTENDANCE_SEQ.NEXTVAL,:student,:sid,:scan,'PRESENT')",dict(student=student,sid=sid,scan=deadline))
        conn.commit()
        def issue(c,student,at=current):
            cursor=c.cursor()
            token=cursor.var(str,size=100)
            cursor.callproc('PR_GENERATE_EXIT_PASS',[student,sid,token,at])
            return token.getvalue()
        def verify(c,token,staff,at=current+timedelta(minutes=1)):
            cursor=c.cursor()
            result=cursor.var(str,size=500)
            cursor.callproc('PR_VERIFY_HOSTEL_RETURN',[token,staff,result,at])
            return result.getvalue().startswith('VERIFIED:')
        token=issue(conn,students[0]);conn.commit()
        check('Issue an eligible pass',bool(token))
        try:
            issue(conn,students[0])
        except oracledb.DatabaseError:
            conn.rollback();check('Reject duplicate issuance',True)
        else:
            raise AssertionError('Duplicate pass was accepted')
        check('Reject wrong-hostel verification',not verify(conn,token,staff2));conn.commit()
        check('Verify matching return',verify(conn,token,staff1));conn.commit()
        cur.execute('SELECT pass_status FROM exit_pass WHERE pass_token=:t',dict(t=token))
        check('Trigger marks pass USED',cur.fetchone()[0]=='USED')
        check('Reject replay',not verify(conn,token,staff1));conn.commit()
        cur.execute("SELECT COUNT(*) FROM audit_log WHERE action_name='RETURN_VERIFIED' AND performed_by=:sf",dict(sf=staff1))
        check('Return audit event is recorded',cur.fetchone()[0]==1)
        token2=issue(conn,students[1]);conn.commit()
        check('Verify before rollback',verify(conn,token2,staff1));conn.rollback()
        cur.execute('SELECT pass_status FROM exit_pass WHERE pass_token=:t',dict(t=token2))
        check('Trigger state rolls back atomically',cur.fetchone()[0]=='ACTIVE')
        token3=issue(conn,students[2]);conn.commit()
        check('Reject expired pass',not verify(conn,token3,staff1,close+timedelta(minutes=15,seconds=1)));conn.commit()
        check('Status function reports expiry',cur.callfunc('FN_CHECK_PASS_STATUS',str,[token3,close+timedelta(minutes=16)])=='EXPIRED')
        check('Return function reports returned',cur.callfunc('FN_GET_STUDENT_RETURN_STATUS',str,[students[0],sid])=='RETURNED')
        cur.callproc('DBMS_OUTPUT.ENABLE',[1000000])
        cur.callproc('PR_GENERATE_UNRETURNED_REPORT',[sid])
        line=cur.var(str,size=32767);status=cur.var(int);lines=[]
        while True:
            cur.callproc('DBMS_OUTPUT.GET_LINE',[line,status])
            if status.getvalue()!=0:
                break
            lines.append(line.getvalue())
        check('Explicit cursor produces pending report',any('Total pending returns:' in (l or '') for l in lines))
        token4=issue(conn,students[3]);conn.commit()
        def concurrent_verify(_):
            with connection() as other:
                ok=verify(other,token4,staff1)
                other.commit()
                return ok
        with ThreadPoolExecutor(max_workers=2) as pool:
            check('Concurrent scans produce exactly one return',sorted(pool.map(concurrent_verify,range(2)))==[False,True])
        def concurrent_issue(_):
            with connection() as other:
                try:
                    issued=issue(other,students[4]);other.commit();return bool(issued)
                except oracledb.DatabaseError:
                    other.rollback();return False
        with ThreadPoolExecutor(max_workers=2) as pool:
            check('Concurrent issue produces exactly one pass',sorted(pool.map(concurrent_issue,range(2)))==[False,True])
    result=dict(backend='oracle',status='passed',checks=checks,executed_at=datetime.now(ZoneInfo('Asia/Kolkata')).isoformat())
    Path(args.output).write_text(json.dumps(result,indent=2)+'\n')
    print(f'{len(checks)} real Oracle acceptance checks passed. Evidence: {args.output}')

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--install',action='store_true',help='Create objects in an empty disposable schema; no drops.')
    parser.add_argument('--output',default='oracle-verification.json')
    try:
        run(parser.parse_args())
    except Exception as exc:
        print(f'Oracle verification did not pass: {exc}',file=sys.stderr)
        sys.exit(1)
