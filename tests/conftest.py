import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import pytest
from app import create_app

@pytest.fixture
def app(tmp_path):
    return create_app({'TESTING':True,'SECRET_KEY':'test-secret','DATABASE_BACKEND':'sqlite',
        'SQLITE_PATH':str(tmp_path/'test.db'),'DEMO_MODE':True,'DEMO_PASSWORD':'library-demo'})

@pytest.fixture
def client(app):
    return app.test_client()

@pytest.fixture
def login(client):
    def do(username):
        client.get('/login')
        with client.session_transaction() as s:
            token=s['csrf']
        return client.post('/login',data={'username':username,'password':'library-demo','csrf':token})
    return do

@pytest.fixture
def post(client):
    def do(path,data=None):
        with client.session_transaction() as s:
            token=s.get('csrf','')
        return client.post(path,data={**(data or {}),'csrf':token},follow_redirects=True)
    return do
