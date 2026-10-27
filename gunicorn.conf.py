import os
bind='0.0.0.0:8000'
workers=int(os.getenv('WEB_WORKERS','2'))
threads=4
worker_class='gthread'
timeout=30
graceful_timeout=30
keepalive=5
max_requests=2000
max_requests_jitter=200
# Leave preload off: Oracle connection pools must be created independently in each worker.
preload_app=False
# Never log URL paths, QR tokens, cookies, credentials or authorization headers.
accesslog=None
errorlog='-'
loglevel='info'
forwarded_allow_ips=''  # Explicit ProxyFix trust is controlled by PROXY_HOPS in Flask.
