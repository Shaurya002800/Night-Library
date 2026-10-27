"""Deployment configuration: fail closed when production prerequisites are absent."""
import os
from urllib.parse import urlparse
from datetime import timedelta
import secrets


def settings():
    production = os.getenv('APP_ENV','development') == 'production'
    return dict(
        APP_ENV=os.getenv('APP_ENV','development'),
        SECRET_KEY=os.getenv('FLASK_SECRET_KEY') or (None if production else secrets.token_hex(32)),
        DATABASE_BACKEND=os.getenv('DATABASE_BACKEND','oracle' if production else 'sqlite').lower(),
        SQLITE_PATH=os.getenv('SQLITE_PATH','instance/night_library.db'),
        DEMO_MODE=os.getenv('DEMO_MODE','false' if production else 'true').lower()=='true',
        DEMO_PASSWORD=os.getenv('DEMO_PASSWORD','' if production else 'library-demo'),
        DB_USER=os.getenv('DB_USER'),DB_PASSWORD=os.getenv('DB_PASSWORD'),DB_DSN=os.getenv('DB_DSN'),
        DB_SCHEMA=os.getenv('DB_SCHEMA',''),
        DB_WALLET_PATH=os.getenv('DB_WALLET_PATH',''),DB_WALLET_PASSWORD=os.getenv('DB_WALLET_PASSWORD',''),
        DB_POOL_MAX=int(os.getenv('DB_POOL_MAX','8')),
        TRUSTED_HOSTS=[h.strip() for h in os.getenv('TRUSTED_HOSTS','').split(',') if h.strip()] or None,
        PUBLIC_BASE_URL=os.getenv('PUBLIC_BASE_URL','http://127.0.0.1:5050').rstrip('/'),
        PROXY_HOPS=int(os.getenv('PROXY_HOPS','0')),
        SESSION_COOKIE_HTTPONLY=True,SESSION_COOKIE_SAMESITE='Lax',SESSION_COOKIE_SECURE=production,
        PERMANENT_SESSION_LIFETIME=timedelta(hours=4),SESSION_IDLE_SECONDS=1800,
        MAX_CONTENT_LENGTH=64*1024,MAX_FORM_PARTS=100,
        ATTENDANCE_WEBHOOK_SECRET=os.getenv('ATTENDANCE_WEBHOOK_SECRET',''),
        ATTENDANCE_PROVIDER=os.getenv('ATTENDANCE_PROVIDER','approved-campus-system'),
        ATTENDANCE_MAX_DELAY_SECONDS=int(os.getenv('ATTENDANCE_MAX_DELAY_SECONDS','3600')),
        OIDC_ISSUER=os.getenv('OIDC_ISSUER','').rstrip('/'),
        OIDC_METADATA_URL=os.getenv('OIDC_METADATA_URL',''),
        OIDC_CLIENT_ID=os.getenv('OIDC_CLIENT_ID',''),OIDC_CLIENT_SECRET=os.getenv('OIDC_CLIENT_SECRET',''),
        AUTH_MODE=os.getenv('AUTH_MODE','local'),
    )


def validate(config):
    if config['DATABASE_BACKEND'] not in ('sqlite','oracle'):
        raise RuntimeError('DATABASE_BACKEND must be sqlite or oracle.')
    import re
    if config.get('DB_SCHEMA') and not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,29}',config['DB_SCHEMA']):
        raise RuntimeError('DB_SCHEMA must be an unquoted Oracle schema identifier.')
    if config['AUTH_MODE'] not in ('local','oidc','both'):
        raise RuntimeError('AUTH_MODE must be local, oidc or both.')
    if config['PROXY_HOPS'] not in (0,1):
        raise RuntimeError('PROXY_HOPS supports zero or one explicitly trusted reverse proxy.')
    if config['AUTH_MODE'] in ('oidc','both'):
        for key in ('OIDC_ISSUER','OIDC_METADATA_URL','OIDC_CLIENT_ID','OIDC_CLIENT_SECRET'):
            if not config.get(key):
                raise RuntimeError(f'{key} is required for OIDC.')
        for key in ('OIDC_ISSUER','OIDC_METADATA_URL'):
            if urlparse(config[key]).scheme!='https':
                raise RuntimeError(f'{key} must use HTTPS.')
    if config['APP_ENV'] != 'production':
        return
    errors=[]
    if not config.get('SECRET_KEY') or len(config['SECRET_KEY'])<32:
        errors.append('FLASK_SECRET_KEY must contain at least 32 random characters')
    if config['DEMO_MODE'] or config['DEMO_PASSWORD']:
        errors.append('demo mode and demo password must be disabled')
    if config['DATABASE_BACKEND']!='oracle':
        errors.append('the production database must be Oracle')
    if not all(config.get(k) for k in ('DB_USER','DB_PASSWORD','DB_DSN')):
        errors.append('Oracle connection settings are required')
    if not (config.get('DB_DSN') or '').lower().startswith('tcps://'):
        errors.append('production DB_DSN must use a tcps:// TLS connection')
    if not config.get('TRUSTED_HOSTS') or any('*' in h for h in config['TRUSTED_HOSTS']):
        errors.append('explicit TRUSTED_HOSTS are required')
    parsed=urlparse(config['PUBLIC_BASE_URL'])
    if parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.path:
        errors.append('PUBLIC_BASE_URL must be an HTTPS origin')
    if parsed.hostname and config.get('TRUSTED_HOSTS') and parsed.hostname not in config['TRUSTED_HOSTS']:
        errors.append('PUBLIC_BASE_URL host must be in TRUSTED_HOSTS')
    if len(config['ATTENDANCE_WEBHOOK_SECRET'])<32:
        errors.append('ATTENDANCE_WEBHOOK_SECRET must contain at least 32 random characters')
    if errors:
        raise RuntimeError('Production configuration rejected: '+'; '.join(errors))
