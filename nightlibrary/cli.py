import click
from flask import current_app
from .auth import provision,change_password
from .db import connect
from .security import audit


def register_cli(app):
    @app.cli.command('bootstrap-admin')
    @click.option('--staff-id',required=True)
    @click.option('--username',required=True)
    @click.option('--name',required=True)
    def bootstrap_admin(staff_id,username,name):
        """Create the first administrator in a clean deployment. No default credentials."""
        if not staff_id or len(staff_id)>10 or not name or len(name)>80 or len(username)>40:
            raise click.ClickException('Invalid staff identity or field length.')
        password=click.prompt('Administrator password (14+ characters)',hide_input=True,confirmation_prompt=True)
        with connect(write=True) as db:
            if db.one("SELECT COUNT(*) n FROM staff WHERE staff_role='ADMIN' AND is_active='Y'")['n']:
                raise click.ClickException('An active administrator already exists. Use normal account provisioning.')
            db.write("INSERT INTO staff VALUES(:id,:name,'ADMIN',NULL,:user,'Y')",dict(id=staff_id,name=name,user=username))
            provision(db,username,'staff',staff_id,password)
            audit(db,'ADMIN_BOOTSTRAPPED','operator','STAFF',staff_id)
        click.echo('Administrator created. No default password was stored.')

    @app.cli.command('create-account')
    @click.option('--username',required=True)
    @click.option('--kind',type=click.Choice(['student','staff']),required=True)
    @click.option('--subject-id',required=True)
    @click.option('--oidc-sub')
    def create_account(username,kind,subject_id,oidc_sub):
        """Provision an existing directory subject. Passwords are prompted, never CLI arguments."""
        password=None if oidc_sub else click.prompt('New password (14+ characters)',hide_input=True,confirmation_prompt=True)
        try:
            with connect(write=True) as db:
                provision(db,username,kind,subject_id,password,current_app.config['OIDC_ISSUER'] if oidc_sub else None,oidc_sub)
                audit(db,'ACCOUNT_PROVISIONED','operator','AUTH_ACCOUNT',username,'Explicit account provisioning')
        except ValueError as exc:
            raise click.ClickException(str(exc))
        click.echo('Account provisioned.')

    @app.cli.command('reset-password')
    @click.option('--username',required=True)
    def reset_password(username):
        """Operator-only recovery. Revokes every existing session."""
        with connect() as db:
            if not db.one('SELECT username FROM auth_account WHERE username=:u',dict(u=username)):
                raise click.ClickException('Account not found.')
        password=click.prompt('New password (14+ characters)',hide_input=True,confirmation_prompt=True)
        try:
            change_password(username,password)
        except ValueError as exc:
            raise click.ClickException(str(exc))
        click.echo('Password changed. Previous sessions revoked.')

    @app.cli.command('maintenance')
    def maintenance():
        """Purge expired authentication sessions and throttle buckets, never domain or audit history."""
        import time
        epoch=int(time.time())
        with connect(write=True) as db:
            db.write('DELETE FROM auth_session WHERE expires_epoch<:epoch',dict(epoch=epoch))
            db.write('DELETE FROM rate_bucket WHERE window_start<:epoch',dict(epoch=epoch-86400))
        click.echo('Expired authentication state removed.')
