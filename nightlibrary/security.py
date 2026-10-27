"""Database-backed throttling and append-only security events across workers."""
import hashlib
import time
from .db import connect,now


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def audit(db,action,actor,record_type,record_id,details=''):
    db.write('''INSERT INTO security_event(action_name,actor,record_type,record_id,event_time,details)
      VALUES(:action,:actor,:type,:id,:time,:details)''',dict(action=action,actor=actor or 'anonymous',type=record_type,id=str(record_id),time=now(),details=details or '-'))


def consume_limit(key,maximum,window=900):
    """Oracle MERGE atomically increments one fixed-window bucket; SQLite serializes writers."""
    start=int(time.time())//window*window
    hashed=digest(f'{key}:{start}')
    with connect(write=True) as db:
        values=dict(key=hashed,start=start)
        if db.oracle:
            # Retry an insert race in a new transaction, not an in-memory per-worker counter.
            try:
                db.write('''MERGE INTO rate_bucket t USING(SELECT :key bucket_key,:start window_start FROM dual) s
                  ON(t.bucket_key=s.bucket_key) WHEN MATCHED THEN UPDATE SET t.hits=t.hits+1
                  WHEN NOT MATCHED THEN INSERT(bucket_key,window_start,hits) VALUES(s.bucket_key,s.window_start,1)''',values)
            except Exception as exc:
                if 'ORA-00001' not in str(exc):
                    raise
                db.write('UPDATE rate_bucket SET hits=hits+1 WHERE bucket_key=:key',dict(key=hashed))
        else:
            db.write('''INSERT INTO rate_bucket VALUES(:key,:start,1)
              ON CONFLICT(bucket_key) DO UPDATE SET hits=hits+1''',values)
        hits=db.one('SELECT hits FROM rate_bucket WHERE bucket_key=:key',dict(key=hashed))['hits']
    return hits<=maximum
