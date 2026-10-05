#!/usr/bin/env python3
"""
jabs_client.py — Minimal HTTP client for the JABS Agent Monitoring API.

Implements the endpoints described in the JABS project's
AGENTS_API_GUIDE.md (repo root of the main jabs_dev project, not part of
this standalone dns_backup_agent repo):
    POST /api/monitoring/events
    POST /api/monitoring/target-purged

This exists so dns_backup.sh (a bash script) can report activity to a
JABS dashboard without hand-rolling JSON in bash. It's intentionally
dependency free (stdlib only: argparse + urllib) so it runs on any box with
python3 and nothing else installed.

Design goals, matching the guide's "treat as fire-and-forget" note:
  - Every call is best-effort. Network failures, timeouts, and non-2xx
    responses are reported on stderr but NEVER raise or exit non-zero,
    so a flaky/absent JABS server never breaks the calling backup job.
  - Short default timeout (10s) so a hung server doesn't stall the caller.

Auth: every request must include the agent's API key via the `--agent-key`
argument (or the JABS_AGENT_KEY environment variable), sent as the
X-API-Key header. Register the agent on the dashboard's Agents page to
obtain a key.

Usage:
    jabs_client.py event --server-url URL --agent-key KEY \
        [--version V] [--agent-type T] [--event-type E] \
        [--message M] [--stage S] [--run-id R] [--job-run-id ID] [--target-id ID] \\
        [--target-label N] [--job-name J] [--backup-type T] \\
        [--source S] [--destination D] [--encrypt true|false] \\
        [--sync true|false] [--status success|failed] \\
        [--duration-seconds F] [--files-backed-up N] \\
        [--bytes-backed-up N] [--bytes-compressed N] \
        [--percent-complete N] [--bytes-per-second F] \
        [--eta-seconds N] [--current-item PATH] \
        [--error-code N] [--error-message M] [--timeout SEC]

Omit a --event-type and --target-id on `event` to send a bare
heartbeat (no backup job created/updated) — see AGENTS_API_GUIDE.md.

    jabs_client.py purge --server-url URL --agent-key KEY \
        --target-id ID --external-id ID1 [--external-id ID2 ...] \
        [--message M]

Call `purge` right after deleting specific rotated-out artifact(s) whose
external_id was previously reported on an `event` call's backup_complete,
to mark the matching run(s) as purged on the dashboard.

See AGENTS_API_GUIDE.md for full field semantics and server behavior.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_TIMEOUT = 10.0


def _post(url, payload, timeout, agent_key):
    """POST JSON, return (status_code_or_None, body_text)."""
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json", "X-API-Key": agent_key or ""},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        return e.code, body
    except Exception as e:
        return None, str(e)


def _report(status, body):
    if status is None:
        print(f"jabs_client: request failed: {body}", file=sys.stderr)
    elif status >= 300:
        print(f"jabs_client: HTTP {status}: {body}", file=sys.stderr)
    elif body:
        print(f"jabs_client: OK ({status}): {body}")


def cmd_event(args):
    payload = {}

    optional_str = {
        "version": args.version,
        "agent_type": args.agent_type,
        "event_type": args.event_type,
        "message": args.message,
        "stage": args.stage,
        "run_id": args.run_id,
        "job_run_id": args.job_run_id,
        "target_id": args.target_id,
        "target_label": args.target_label,
        "job_name": args.job_name,
        "backup_type": args.backup_type,
        "source": args.source,
        "destination": args.destination,
        "status": args.status,
        "current_item": args.current_item,
        "error_message": args.error_message,
        "cron_schedule": args.cron_schedule,
    }
    for key, val in optional_str.items():
        if val is not None and val != "":
            payload[key] = val

    if args.encrypt is not None:
        payload["encrypt"] = args.encrypt
    if args.sync is not None:
        payload["sync"] = args.sync
    if args.duration_seconds is not None:
        payload["duration_seconds"] = args.duration_seconds
    if args.files_backed_up is not None:
        payload["files_backed_up"] = args.files_backed_up
    if args.bytes_backed_up is not None:
        payload["bytes_backed_up"] = args.bytes_backed_up
    if args.bytes_compressed is not None:
        payload["bytes_compressed"] = args.bytes_compressed
    if args.bytes_per_second is not None:
        payload["bytes_per_second"] = args.bytes_per_second
    if args.error_code is not None:
        payload["error_code"] = args.error_code
    if args.external_id is not None and args.external_id != "":
        payload["external_id"] = args.external_id

    url = args.server_url.rstrip("/") + "/api/monitoring/events"
    status, body = _post(url, payload, args.timeout, args.agent_key)
    _report(status, body)


def cmd_purge(args):
    external_ids = [x for x in (args.external_id or []) if x]
    if not external_ids:
        print("jabs_client: purge requires at least one --external-id", file=sys.stderr)
        return

    payload = {
        "target_id": args.target_id,
        "external_ids": external_ids,
    }
    if args.message:
        payload["message"] = args.message

    url = args.server_url.rstrip("/") + "/api/monitoring/target-purged"
    status, body = _post(url, payload, args.timeout, args.agent_key)
    _report(status, body)


def _str2bool(v):
    return str(v).strip().lower() in ("1", "true", "yes", "y", "on")


def build_parser():
    parser = argparse.ArgumentParser(description="JABS agent monitoring API client")
    sub = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--server-url", required=True, help="e.g. http://jabs-server:5001")
    common.add_argument("--agent-key", default=os.environ.get("JABS_AGENT_KEY"),
                         help="API key for this agent (default: JABS_AGENT_KEY env var)")
    common.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)

    ev = sub.add_parser("event", parents=[common], help="POST /api/monitoring/events")
    ev.add_argument("--version")
    ev.add_argument("--agent-type")
    ev.add_argument("--event-type", choices=["heartbeat", "backup_complete", "error"])
    ev.add_argument("--message")
    ev.add_argument("--stage")
    ev.add_argument("--run-id")
    ev.add_argument("--job-run-id", help="Shared ID for every target/pair in one overall script invocation")
    ev.add_argument("--target-id")
    ev.add_argument("--target-label")
    ev.add_argument("--job-name")
    ev.add_argument("--backup-type")
    ev.add_argument("--source")
    ev.add_argument("--destination")
    ev.add_argument("--encrypt", type=_str2bool)
    ev.add_argument("--sync", type=_str2bool)
    ev.add_argument("--status", choices=["success", "failed", "stopped"])
    ev.add_argument("--duration-seconds", type=float)
    ev.add_argument("--files-backed-up", type=int)
    ev.add_argument("--bytes-backed-up", type=int)
    ev.add_argument("--bytes-compressed", type=int)
    ev.add_argument("--bytes-per-second", type=float)
    ev.add_argument("--current-item")
    ev.add_argument("--error-code", type=int)
    ev.add_argument("--error-message")
    ev.add_argument("--cron-schedule", help="Comma-separated cron expression(s) for job_name's schedule")
    ev.add_argument("--external-id", help="Opaque ID of the artifact this run produced (e.g. image filename)")
    ev.set_defaults(func=cmd_event)

    pg = sub.add_parser("purge", parents=[common], help="POST /api/monitoring/target-purged")
    pg.add_argument("--target-id", required=True)
    pg.add_argument("--external-id", action="append",
                     help="external_id of a deleted artifact; repeat for multiple")
    pg.add_argument("--message")
    pg.set_defaults(func=cmd_purge)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.agent_key:
        print("jabs_client: warning: no API key provided (--agent-key or JABS_AGENT_KEY)", file=sys.stderr)
    try:
        args.func(args)
    except Exception as e:
        # This client is best-effort by design — never propagate a hard
        # failure back to the caller (see module docstring).
        print(f"jabs_client: unexpected error: {e}", file=sys.stderr)
    sys.exit(0)


if __name__ == "__main__":
    main()
