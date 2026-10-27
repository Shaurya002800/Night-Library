"""WSGI entry point. Configuration validation runs before accepting traffic."""
from app import create_app
application=create_app()
