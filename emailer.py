#!/usr/bin/env python3
"""
emailer.py — Immediate email alerts for a JABS bash agent.

Independent of the JABS dashboard (which only sends digests). Called by the
agent's bash script; the body is read from stdin. Stdlib only, so it runs on
any box with python3 and nothing else installed.

Usage:
    emailer.py --subject SUBJECT [--event-type error|success|test] < body.txt

Settings (environment variables, exported by the calling script from its .conf):
    EMAIL_SMTP_SERVER, EMAIL_SMTP_PORT (587), EMAIL_USE_TLS (true),
    EMAIL_TO_ADDRS (comma-separated), EMAIL_NOTIFY_ON_ERROR (true),
    EMAIL_NOTIFY_ON_SUCCESS (false)

Credentials come from a .env file next to this script (never from argv):
    JABS_SMTP_USERNAME, JABS_SMTP_PASSWORD
    ENV_MODE=development prefixes the subject with "[DEV]".

Exit codes: 0 = sent, 1 = failed (reason on stderr), 2 = skipped (email not
configured, or this event type is disabled). "test" always sends.
"""
import argparse
import os
import smtplib
import socket
import sys
from email.mime.text import MIMEText

ENV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
SMTP_TIMEOUT = 10


def _load_env_file(path):
    """Parse KEY=VALUE lines from a .env file; returns {} if it is missing."""
    values = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                key, _, value = line.partition("=")
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                    value = value[1:-1]
                values[key.strip()] = value
    except OSError:
        pass
    return values


def _is_true(value, default):
    if value is None or value == "":
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


def send_email(subject, body, event_type="error", env_path=ENV_PATH):
    """Send one email; returns 0 (sent), 1 (failed) or 2 (skipped)."""
    server_host = os.environ.get("EMAIL_SMTP_SERVER", "").strip()
    to_addrs = [a.strip() for a in os.environ.get("EMAIL_TO_ADDRS", "").split(",") if a.strip()]
    if not server_host or not to_addrs:
        return 2

    if event_type == "error":
        enabled = _is_true(os.environ.get("EMAIL_NOTIFY_ON_ERROR"), True)
    elif event_type == "success":
        enabled = _is_true(os.environ.get("EMAIL_NOTIFY_ON_SUCCESS"), False)
    else:
        enabled = True
    if not enabled:
        return 2

    creds = _load_env_file(env_path)  # .env wins over inherited shell/cron env vars
    username = creds.get("JABS_SMTP_USERNAME") or os.environ.get("JABS_SMTP_USERNAME")
    password = creds.get("JABS_SMTP_PASSWORD") or os.environ.get("JABS_SMTP_PASSWORD")
    if not username or not password:
        print(f"SMTP credentials missing: set JABS_SMTP_USERNAME and JABS_SMTP_PASSWORD in {env_path}",
              file=sys.stderr)
        return 1

    try:
        port = int(os.environ.get("EMAIL_SMTP_PORT") or 587)
    except ValueError:
        print(f"Invalid EMAIL_SMTP_PORT: {os.environ.get('EMAIL_SMTP_PORT')!r}", file=sys.stderr)
        return 1

    if (creds.get("ENV_MODE") or os.environ.get("ENV_MODE")) == "development":
        subject = f"[DEV] {subject}"

    msg = MIMEText(body, "plain")
    msg["Subject"] = subject
    msg["From"] = username
    msg["To"] = ", ".join(to_addrs)

    try:
        server = smtplib.SMTP(server_host, port, timeout=SMTP_TIMEOUT)
        try:
            if _is_true(os.environ.get("EMAIL_USE_TLS"), True):
                server.starttls()
            server.login(username, password)
            server.sendmail(username, to_addrs, msg.as_string())
        finally:
            try:
                server.quit()
            except Exception:  # pylint: disable=broad-except
                pass
    except (smtplib.SMTPException, OSError, socket.timeout) as e:
        print(f"Failed to send email '{subject}': {e}", file=sys.stderr)
        return 1

    print(f"Email sent: '{subject}' to {', '.join(to_addrs)}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Send a JABS agent alert email (body on stdin).")
    parser.add_argument("--subject", required=True)
    parser.add_argument("--event-type", choices=("error", "success", "test"), default="error")
    args = parser.parse_args(argv)
    return send_email(args.subject, sys.stdin.read(), args.event_type)


if __name__ == "__main__":
    sys.exit(main())
