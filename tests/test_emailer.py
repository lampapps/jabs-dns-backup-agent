"""Unit tests for emailer.py (stdlib unittest, no network)."""
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import emailer  # noqa: E402

BASE_ENV = {
    "EMAIL_SMTP_SERVER": "smtp.example.com",
    "EMAIL_SMTP_PORT": "587",
    "EMAIL_USE_TLS": "true",
    "EMAIL_TO_ADDRS": "a@example.com, b@example.com",
}


class EmailerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env_path = os.path.join(self.tmp.name, ".env")
        with open(self.env_path, "w", encoding="utf-8") as fh:
            fh.write("# comment\nJABS_SMTP_USERNAME='user@example.com'\n"
                     'export JABS_SMTP_PASSWORD="s3cret"\n')

    def _send(self, env, event_type="error", env_path=None):
        with mock.patch.dict(os.environ, env, clear=True):
            return emailer.send_email("subj", "body", event_type, env_path or self.env_path)

    def test_load_env_file_parses_quotes_comments_export(self):
        values = emailer._load_env_file(self.env_path)
        self.assertEqual(values["JABS_SMTP_USERNAME"], "user@example.com")
        self.assertEqual(values["JABS_SMTP_PASSWORD"], "s3cret")

    def test_load_env_file_missing_returns_empty(self):
        self.assertEqual(emailer._load_env_file(os.path.join(self.tmp.name, "nope")), {})

    def test_skipped_when_not_configured(self):
        self.assertEqual(self._send({}), 2)

    def test_error_enabled_by_default_success_disabled(self):
        with mock.patch("emailer.smtplib.SMTP") as smtp:
            self.assertEqual(self._send(BASE_ENV, "error"), 0)
            self.assertEqual(self._send(BASE_ENV, "success"), 2)
        self.assertEqual(smtp.call_count, 1)

    def test_success_enabled_by_flag(self):
        with mock.patch("emailer.smtplib.SMTP"):
            self.assertEqual(self._send({**BASE_ENV, "EMAIL_NOTIFY_ON_SUCCESS": "true"}, "success"), 0)

    def test_error_disabled_by_flag(self):
        self.assertEqual(self._send({**BASE_ENV, "EMAIL_NOTIFY_ON_ERROR": "false"}, "error"), 2)

    def test_test_event_always_sends(self):
        env = {**BASE_ENV, "EMAIL_NOTIFY_ON_ERROR": "false"}
        with mock.patch("emailer.smtplib.SMTP"):
            self.assertEqual(self._send(env, "test"), 0)

    def test_sends_to_all_recipients_with_tls_and_login(self):
        with mock.patch("emailer.smtplib.SMTP") as smtp:
            self.assertEqual(self._send(BASE_ENV), 0)
        server = smtp.return_value
        smtp.assert_called_once_with("smtp.example.com", 587, timeout=emailer.SMTP_TIMEOUT)
        server.starttls.assert_called_once()
        server.login.assert_called_once_with("user@example.com", "s3cret")
        self.assertEqual(server.sendmail.call_args[0][1], ["a@example.com", "b@example.com"])
        server.quit.assert_called_once()

    def test_tls_can_be_disabled(self):
        with mock.patch("emailer.smtplib.SMTP") as smtp:
            self._send({**BASE_ENV, "EMAIL_USE_TLS": "false"})
        smtp.return_value.starttls.assert_not_called()

    def test_dev_mode_prefixes_subject(self):
        with open(self.env_path, "a", encoding="utf-8") as fh:
            fh.write("ENV_MODE=development\n")
        with mock.patch("emailer.smtplib.SMTP") as smtp:
            self._send(BASE_ENV)
        self.assertIn("Subject: [DEV] subj", smtp.return_value.sendmail.call_args[0][2])

    def test_missing_credentials_fails(self):
        self.assertEqual(self._send(BASE_ENV, env_path=os.path.join(self.tmp.name, "nope")), 1)

    def test_smtp_error_fails(self):
        with mock.patch("emailer.smtplib.SMTP", side_effect=OSError("unreachable")):
            self.assertEqual(self._send(BASE_ENV), 1)

    def test_invalid_port_fails(self):
        self.assertEqual(self._send({**BASE_ENV, "EMAIL_SMTP_PORT": "abc"}), 1)


if __name__ == "__main__":
    unittest.main()
