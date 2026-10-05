# DNS Backup Agent

A Bash script that creates a full compressed SD card image of each Raspberry Pi 4 HA DNS node and writes it to a NAS — with **zero downtime**. Runs from a workstation and orchestrates both nodes over SSH.

Each Raspberry Pi4 runs keepalived, technitium, and caddy. All clients on the LAN point DNS to one Virtual IP. If DNS1 goes down, the Virtual IP is moved to the DNS2. This script automates the process of shutting down DNS1, saving an image of it to a NAS, restarting DNS1, then shutting down DNS2 and saving an image of that. 

---

## File layout

```
/mnt/nas-unas/backups/
├── dns1/
│   └── sd_image_20260501_030000.img.gz
└── dns2/
    └── sd_image_20260501_030512.img.gz

dns_backup_agent/
└── logs/
    └── sd_image_backup_20260501_030000.log   ← orchestration log (covers both nodes)
```

Logs are kept locally next to the script (not on the NAS) and are pruned by
`cleanup_old_images()` on the same `IMAGE_RETENTION_DAYS` schedule as the
image files they document.

---

## How it works

For each node in turn:
1. Stop services — `keepalived` is stopped first, immediately handing the virtual IP to the peer node. DNS clients see zero downtime.
2. Wait briefly for the peer to claim the VIP.
3. Stream the SD card over SSH (`dd | gzip`) directly into a `.img.gz` file on the NAS.
4. Restart services in reverse order; wait for the node to fully rejoin before touching the peer.

An `EXIT` trap ensures services are restarted even if the script is interrupted.

---

## Prerequisites

**1. SSH key authentication** (required — the script uses `BatchMode=yes` and will not prompt for passwords):

```bash
# On your workstation
ssh-keygen -t ed25519 -C "dns_backup"               # if you don't have a key yet
ssh-copy-id pi@dns1
ssh-copy-id pi@dns2
```

**2. Passwordless sudo for `dd` and `systemctl`** on each node:

```bash
# Run on dns1 (and repeat on dns2)
echo 'pi ALL=(ALL) NOPASSWD: /usr/bin/dd, /usr/bin/systemctl' \
  | sudo tee /etc/sudoers.d/sd_image_backup
sudo chmod 440 /etc/sudoers.d/sd_image_backup
```

> Only `dd` and `systemctl` are granted passwordless sudo, nothing broader.

---

## Installation (workstation)

Runs in place from this repo directory — `dns_backup.sh` only sources a
config file next to itself (`dns_backup.conf`), so no `/usr/local/sbin` or
`/etc` install step is needed:

```bash
cp dns_backup.conf.example dns_backup.conf
chmod 600 dns_backup.conf

nano dns_backup.conf   # set DNS1_HOST, DNS2_HOST, SSH_USER
```

---

## Test without writing anything

```bash
./dns_backup.sh --dry-run
```

---

## Scheduling (workstation cron, monthly)

```bash
sudo tee /etc/cron.d/dns_backup <<'EOF'
0 3 1 * * root /path/to/dns_backup_agent/dns_backup.sh
EOF
```

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `DNS1_HOST` | `dns1` | Hostname or IP of the first node |
| `DNS2_HOST` | `dns2` | Hostname or IP of the second node |
| `SSH_USER` | `pi` | SSH login user on each node |
| `SD_DEVICE` | `/dev/mmcblk0` | SD card block device (built-in slot on RPi4) |
| `STOP_SERVICES` | `keepalived dns caddy` | Services to stop (space-separated, stop order) |
| `FAILOVER_WAIT` | `20` | Seconds to wait after stopping keepalived before imaging |
| `REJOIN_WAIT` | `30` | Seconds to wait after restarting a node before imaging the peer |
| `NAS_MOUNT` | `/mnt/nas-unas` | NAS mount point on the workstation |
| `BACKUP_BASE_DIR` | `/mnt/nas-unas/backups` | Root directory for image output |
| `IMAGE_RETENTION_DAYS` | `90` | Days to keep old `.img.gz` files (0 = keep forever) |
| `JABS_DASHBOARD_URL` | (unset) | JABS dashboard base URL, e.g. `http://jabs-server:5001`. Set to enable reporting; leave unset/empty to disable. (`JABS_SERVER_URL` still works as a deprecated alias.) |
| `JABS_AGENT_KEY` | (unset) | API key for this agent, generated when you register it on the dashboard's Agents page. |
| `JABS_TIMEOUT` | `10` | Per-request timeout (seconds) for calls to the JABS dashboard. |

The version reported to the dashboard is not a config option — it's the
`SCRIPT_VERSION` constant at the top of `dns_backup.sh`, bumped in git each
time the script changes.

---

## JABS agent monitoring (optional)

`dns_backup.sh` can report each node's imaging run to a JABS dashboard as a
monitored job, via `jabs_client.py` (a small stdlib-only Python HTTP client
— no `pip install` needed, requires `python3`).

Enable it in `dns_backup.conf`:

```bash
JABS_DASHBOARD_URL="http://<server-ip>:5001"  #:5000 for production,:5001 for development as set in your dashboard .env file
JABS_AGENT_KEY=""                          # paste the key from the dashboard here
JABS_TIMEOUT=10
```

Before the first run, you must register this agent on the JABS dashboard's
Agents page — that's also where you set this agent's hostname/IP for
display (the dashboard ignores any hostname/IP an agent reports; it isn't
used for auth or stored from event payloads). Registering generates a
unique API key; paste it into `JABS_AGENT_KEY`. Every request is
authenticated by that key alone (sent as the `X-API-Key` header).

**How nodes map to JABS jobs:** each node (`DNS1_HOST`/`DNS2_HOST`) is
reported under its hostname as the job name. Each node uses one stable
`target_id` (the host name) shared across every run, rather than a new
dated ID per run — so the dashboard shows one job target per node instead
of a new one on every image.
Each node's run sends:

- a start event when imaging begins,
- a generic "still imaging" heartbeat every `JABS_PROGRESS_INTERVAL` seconds
  (default 300), plus richer best-effort progress every ~5s parsed from
  `dd status=progress` (bytes copied so far and transfer rate — no
  percent/ETA, since the total SD card size isn't known up front),
- a completion event (`backup_complete` or `error`) when it finishes, with
  duration and the resulting image file's size,
- or, if the script is interrupted (signal/crash) mid-image, a
  `backup_complete` event with `status=stopped` from the `EXIT` trap — the
  job is finalized (not left "running") but distinct from success/failure.

A bare heartbeat (host online + agent version, no job) is also sent once at
the very start of each run.

**Retention:** this agent has no API to tell the dashboard when to purge its
job records. The dashboard purges job records per its own agent-type-aware
retention policy (`retention.max_days`/`mode`, keyed by `agent_type` — see
the dashboard's README.md); `IMAGE_RETENTION_DAYS` here only controls
pruning of this script's own local `.img.gz` files, independent of the
dashboard's copy of the data.

Reporting is fire-and-forget and best-effort: it's skipped entirely during
`--dry-run`, and any failure (server unreachable, bad response, `python3`
missing) is logged as a `WARN` but never fails the imaging run itself. Leave
`JABS_DASHBOARD_URL` unset/empty to disable it completely.

---

## Restoring to a new SD card

Insert the replacement SD card into your workstation. Find its device with `lsblk`, then:

```bash
gunzip -c /mnt/nas-unas/backups/dns1/sd_image_20260501_030000.img.gz \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the actual device of the new card. The restored card is an exact clone — insert it into the RPi and it boots normally. The card must be at least as large as the original.

---

