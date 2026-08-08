# sd_image_backup

A Bash script that creates a full compressed SD card image of each Raspberry Pi 4 HA DNS node and writes it to a NAS — with **zero downtime**. Runs from your workstation and orchestrates both nodes over SSH.

---

## File layout

```
/mnt/nas-unas/backups/
├── dns1/
│   └── sd_image_20260501_030000.img.gz
├── dns2/
│   └── sd_image_20260501_030512.img.gz
└── sd_image_backup_20260501_030000.log   ← orchestration log (covers both nodes)
```

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
ssh-keygen -t ed25519 -C "sd_image_backup"          # if you don't have a key yet
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

```bash
sudo cp sd_image_backup.sh /usr/local/sbin/sd_image_backup.sh
sudo chmod 755 /usr/local/sbin/sd_image_backup.sh

sudo cp sd_image_backup.conf.example /etc/sd_image_backup.conf
sudo chmod 600 /etc/sd_image_backup.conf
sudo chown root:root /etc/sd_image_backup.conf

sudo nano /etc/sd_image_backup.conf   # set DNS1_HOST, DNS2_HOST, SSH_USER
```

---

## Test without writing anything

```bash
sudo /usr/local/sbin/sd_image_backup.sh --dry-run
```

---

## Scheduling (workstation cron, monthly)

```bash
sudo tee /etc/cron.d/sd_image_backup <<'EOF'
0 3 1 * * root /usr/local/sbin/sd_image_backup.sh
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
| `STOP_SERVICES` | `keepalived technitium caddy` | Services to stop (space-separated, stop order) |
| `FAILOVER_WAIT` | `20` | Seconds to wait after stopping keepalived before imaging |
| `REJOIN_WAIT` | `30` | Seconds to wait after restarting a node before imaging the peer |
| `NAS_MOUNT` | `/mnt/nas-unas` | NAS mount point on the workstation |
| `BACKUP_BASE_DIR` | `/mnt/nas-unas/backups` | Root directory for image output |
| `IMAGE_RETENTION_DAYS` | `90` | Days to keep old `.img.gz` files (0 = keep forever) |
| `JABS_SERVER_URL` | (unset) | JABS dashboard base URL, e.g. `http://jabs-server:5001`. Set to enable reporting; leave unset/empty to disable. |
| `JABS_AGENT_KEY` | (unset) | API key for this agent, generated when you register it on the dashboard's Agents page. |
| `JABS_HOSTNAME` | `$(hostname)` | Informational only (shown on the Agents page; not used for authentication). |
| `JABS_IP_ADDRESS` | (unset) | Informational only. |
| `JABS_AGENT_VERSION` | `0.1.0` | Reported on the agent record; bump when you change this script. |
| `JABS_TIMEOUT` | `10` | Per-request timeout (seconds) for calls to the JABS dashboard. |

---

## JABS agent monitoring (optional)

`dns_backup.sh` can report each node's imaging run to a JABS dashboard as a
monitored job, via `jabs_client.py` (a small stdlib-only Python HTTP client
— no `pip install` needed, requires `python3`).

Enable it in `dns_backup.conf`:

```bash
JABS_SERVER_URL="http://jabs-server:5001"
JABS_AGENT_KEY=""                # paste the key from the dashboard here
JABS_HOSTNAME="$(hostname)"      # informational only, shown on the Agents page
JABS_IP_ADDRESS="192.168.1.50"   # informational only
JABS_TIMEOUT=10
```

Before the first run, you must register this agent on the JABS dashboard's
Agents page. Registering generates a unique API key; paste it into
`JABS_AGENT_KEY`. Every request is authenticated by that key alone (sent as
the `X-API-Key` header) — `JABS_HOSTNAME`/`JABS_IP_ADDRESS` are stored for
display only and don't need to match anything.

**How nodes map to JABS jobs:** each node (`DNS1_HOST`/`DNS2_HOST`) is
reported under its hostname as the job name. Unlike an ongoing mirror sync,
every run produces a brand-new dated image file, so each run gets its own
`backup_set_id` (`<host>-<timestamp>`) — just like a versioned backup agent.
Each node's run sends:

- a start event when imaging begins,
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
`JABS_SERVER_URL` unset/empty to disable it completely.

---

## Restoring to a new SD card

Insert the replacement SD card into your workstation. Find its device with `lsblk`, then:

```bash
gunzip -c /mnt/nas-unas/backups/dns1/sd_image_20260501_030000.img.gz \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the actual device of the new card. The restored card is an exact clone — insert it into the RPi and it boots normally. The card must be at least as large as the original.

---

## License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
