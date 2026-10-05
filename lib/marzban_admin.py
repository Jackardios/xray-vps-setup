#!/usr/bin/env python3
"""Run inside the Marzban container to import the installer-managed sudo admin."""
import sys


def initialize():
    from decouple import config
    from app.db import GetDB, crud
    from app.db.models import User
    from app.models.admin import AdminCreate, AdminPartialModify

    username, password = config('SUDO_USERNAME'), config('SUDO_PASSWORD')
    if not username or not password:
        raise ValueError('Missing administrator credentials')
    with GetDB() as db:
        admin = crud.get_admin(db, username=username)
        if admin is None:
            admin = crud.create_admin(db, AdminCreate(username=username, password=password, is_sudo=True))
        else:
            # v0.8.4's partial model requires these nullable fields. Its CRUD
            # function ignores None, preserving existing notification settings.
            admin = crud.partial_update_admin(db, admin, AdminPartialModify(
                password=password, is_sudo=True, telegram_id=None, discord_webhook=None))
        db.query(User).filter_by(admin_id=None).update({'admin_id': admin.id})
        db.commit()


if __name__ == '__main__':
    try:
        initialize()
    except Exception as error:
        # Validation errors and rich CLI tracebacks can expose the password.
        print(f'Marzban administrator initialization failed ({type(error).__name__})', file=sys.stderr)
        sys.exit(1)
