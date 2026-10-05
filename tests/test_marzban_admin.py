import contextlib
from dataclasses import dataclass
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / 'lib/marzban_admin.py'
spec = importlib.util.spec_from_file_location('marzban_admin', SCRIPT)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


@dataclass
class PartialModify:
    # Required nullable fields reproduce the Marzban/Pydantic validation error.
    password: str
    is_sudo: bool
    telegram_id: object
    discord_webhook: object


class AdministratorTests(unittest.TestCase):
    def setUp(self):
        self.current = SimpleNamespace(id=7, telegram_id=123, discord_webhook='https://discord.com/api/webhooks/test')
        self.crud = Mock()
        self.crud.get_admin.return_value = self.current
        self.crud.partial_update_admin.return_value = self.current
        self.crud.create_admin.return_value = SimpleNamespace(id=8)
        self.db = Mock()
        self.user_model = object()
        self.modules = {
            'decouple': SimpleNamespace(config={'SUDO_USERNAME': 'test_admin', 'SUDO_PASSWORD': 'test_password'}.get),
            'app.db': SimpleNamespace(GetDB=lambda: contextlib.nullcontext(self.db), crud=self.crud),
            'app.db.models': SimpleNamespace(User=self.user_model),
            'app.models.admin': SimpleNamespace(AdminCreate=SimpleNamespace, AdminPartialModify=PartialModify),
        }

    def initialize(self):
        with patch.dict(sys.modules, self.modules):
            helper.initialize()

    def test_existing_admin_with_required_nullable_fields(self):
        self.initialize()
        self.crud.create_admin.assert_not_called()
        db, current, changes = self.crud.partial_update_admin.call_args.args
        self.assertIs(db, self.db)
        self.assertIs(current, self.current)
        self.assertEqual((changes.password, changes.is_sudo), ('test_password', True))
        self.assertIsNone(changes.telegram_id)
        self.assertIsNone(changes.discord_webhook)
        self.assertEqual((self.current.telegram_id, self.current.discord_webhook),
                         (123, 'https://discord.com/api/webhooks/test'))
        self.db.query.assert_called_once_with(self.user_model)
        self.db.query.return_value.filter_by.assert_called_once_with(admin_id=None)
        self.db.query.return_value.filter_by.return_value.update.assert_called_once_with({'admin_id': 7})
        self.db.commit.assert_called_once_with()

    def test_fresh_admin_is_created(self):
        self.crud.get_admin.return_value = None
        self.initialize()
        self.crud.partial_update_admin.assert_not_called()
        created = self.crud.create_admin.call_args.args[1]
        self.assertEqual(vars(created), {'username': 'test_admin', 'password': 'test_password', 'is_sudo': True})
        self.db.query.return_value.filter_by.return_value.update.assert_called_once_with({'admin_id': 8})

    def test_missing_credentials_do_not_write_database(self):
        self.modules['decouple'].config = lambda key: ''
        with self.assertRaises(ValueError):
            self.initialize()
        self.crud.get_admin.assert_not_called()
        self.db.commit.assert_not_called()

    def test_database_failure_is_not_reported_as_success(self):
        self.crud.partial_update_admin.side_effect = RuntimeError('database unavailable')
        with self.assertRaises(RuntimeError):
            self.initialize()
        self.db.query.assert_not_called()
        self.db.commit.assert_not_called()

    def test_error_output_does_not_expose_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'decouple.py').write_text(
                'def config(key):\n    raise ValueError("SECRET_PASSWORD")\n')
            code = '''
import runpy,sys
from types import SimpleNamespace
sys.path.insert(0,sys.argv[1])
sys.modules['app.db']=SimpleNamespace(GetDB=None,crud=None)
sys.modules['app.db.models']=SimpleNamespace(User=None)
sys.modules['app.models.admin']=SimpleNamespace(AdminCreate=None,AdminPartialModify=None)
runpy.run_path(sys.argv[2],run_name='__main__')
'''
            result = subprocess.run([sys.executable, '-c', code, directory, str(SCRIPT)],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('ValueError', result.stderr)
        self.assertNotIn('SECRET_PASSWORD', result.stdout + result.stderr)
        self.assertNotIn('Traceback', result.stderr)
