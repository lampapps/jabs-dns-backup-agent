#!/usr/bin/env bash
# =============================================================================
# dns_backup.sh
# Creates a compressed full SD card image of each HA DNS node via SSH.
#
# For each node in turn:
#   1. Stop services (keepalived first → VIP fails over to the peer node)
#   2. Wait for the peer to claim the VIP
#   3. Stream dd | gzip over SSH writing the image to the NAS
#   4. Restart services and wait for the node to fully rejoin
#   5. Repeat for the other node
#
# Run from your WORKSTATION (not on the RPi). Requires SSH key-based
# authentication with passwordless sudo for 'dd' and 'systemctl' on each node.
#
# Usage:
#   ./dns_backup.sh [--dry-run] [--help]
#
# Config file (sourced if present, in the same directory as this script):
#   dns_backup.conf
#
#   python3      — only required if JABS_DASHBOARD_URL is set (see below).
#                  Used to run jabs_client.py, which reports imaging activity
#                  to a JABS dashboard's Agent Monitoring API.
#                  Debian/Ubuntu : sudo apt install python3
#                  RHEL/Fedora   : sudo dnf install python3
#
# Cron example (monthly at 03:00, on your workstation):
#   0 3 1 * * /usr/local/sbin/dns_backup.sh
# =============================================================================

set -uo pipefail

# Reported to the JABS dashboard as this agent's version. 
readonly SCRIPT_VERSION="0.2.1" 

# -----------------------------------------------------------------------------
# CONFIGURATION — defaults; override in dns_backup.conf or environment
# -----------------------------------------------------------------------------
DNS1_HOST="${DNS1_HOST:-dns1}"        # hostname or IP of first node
DNS2_HOST="${DNS2_HOST:-dns2}"        # hostname or IP of second node
SSH_USER="${SSH_USER:-pi}"            # SSH login user on each node

# Built-in SD card block device on RPi4
SD_DEVICE="${SD_DEVICE:-/dev/mmcblk0}"

# Space-separated list of services to stop before imaging, IN STOP ORDER.
# keepalived MUST be first so the VIP immediately fails over to the peer.
# They are restarted in reverse order after imaging.
STOP_SERVICES="${STOP_SERVICES:-keepalived dns caddy}"

# Seconds to wait after stopping keepalived before starting the image.
# Gives the peer node time to claim the VIP.
FAILOVER_WAIT="${FAILOVER_WAIT:-20}"

# Seconds to wait after restarting services on a node before imaging the peer.
# Gives the restarted node time to reclaim the VIP and fully rejoin.
REJOIN_WAIT="${REJOIN_WAIT:-30}"

# NAS mount point — must be mounted and writable on this workstation
NAS_MOUNT="${NAS_MOUNT:-/mnt/nas-unas}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-${NAS_MOUNT}/backups}"

# Days to keep old image files per node (0 = keep forever)
IMAGE_RETENTION_DAYS="${IMAGE_RETENTION_DAYS:-90}"

# -----------------------------------------------------------------------------
# Load config file (must be owner-readable only — may contain SSH details)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/dns_backup.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ── JABS agent monitoring — defaults, so a config from before this feature
# existed still loads fine (JABS reporting simply stays disabled) ─────────
JABS_CLIENT="${SCRIPT_DIR}/jabs_client.py"
# JABS_DASHBOARD_URL is the current name; JABS_SERVER_URL still works as a
# deprecated alias for configs written before the Dashboard rename.
: "${JABS_DASHBOARD_URL:=${JABS_SERVER_URL:-}}"
: "${JABS_AGENT_KEY:=}"
JABS_AGENT_VERSION="${SCRIPT_VERSION}"
: "${JABS_TIMEOUT:=10}"

# Single job name covering the entire run (both nodes); each node still
# reports its own host as the job target (target_id/target_label).
: "${JOB_NAME:=DNS Backup}"

# Optional: cron expression matching this script's crontab entry, reported
# to the dashboard for the "Next Event" column. Purely advisory — this
# script still only runs whenever cron actually invokes it.
: "${JOB_CRON:=}"

# Seconds between progress heartbeats sent while a node's dd/gzip pipeline
# is running (it can take a long time with no other natural checkpoint).
: "${JABS_PROGRESS_INTERVAL:=300}"

# Seconds between dd status=progress reports (local log + JABS POST) while
# imaging. Each report forks a python3 process; too short an interval causes
# enough concurrent fork/pipe churn alongside the ssh|gzip pipeline to
# occasionally surface transient "write error: Resource temporarily
# unavailable" EAGAIN errors on the script's own stdout.
: "${JABS_DD_PROGRESS_INTERVAL:=30}"

# -----------------------------------------------------------------------------
# Derived runtime values (computed after config is sourced)
# -----------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Logs live locally next to the script (same style as the other JABS agents),
# not on the NAS alongside the images. Old logs are pruned in
# cleanup_old_images(), alongside their associated image files.
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/sd_image_backup_${TIMESTAMP}.log"

DRY_RUN=false
ERRORS=0

# Trap state — tracks whether services on a node are currently stopped.
# The EXIT trap uses this to restart services if the script is interrupted.
_TRAP_NODE=""
_TRAP_SERVICES_STOPPED=false

# In-flight job tracking, set by image_node() around each node's imaging
# run, cleared once that node's job is finalized. Lets the EXIT trap report
# the job as "stopped" on the JABS dashboard if the script is interrupted
# mid-image — otherwise it would stay stuck at status='running' forever.
CURRENT_RUN_ID=""
CURRENT_JOB_NAME=""
CURRENT_TARGET_ID=""
CURRENT_TARGET_LABEL=""
CURRENT_JOB_START_EPOCH=0

# Shared by both DNS1/DNS2 nodes in one script invocation (set once in
# main()) so the dashboard can group them into a single "job run" via
# --job-run-id.
JOB_RUN_ID=""

# PID of the background periodic-progress-heartbeat loop (see
# _start_progress_heartbeat/_stop_progress_heartbeat), if one is running.
JABS_PROGRESS_PID=""

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local ts line
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf -v line '[%s] [%-5s] %s' "$ts" "$level" "$*"
    echo "$line"
    if [[ -d "$(dirname "$LOG_FILE")" ]]; then
        echo "$line" >> "$LOG_FILE"
    fi
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

die() {
    log_error "$*"
    exit 1
}

# -----------------------------------------------------------------------------
# SSH helper
# -----------------------------------------------------------------------------
_ssh() {
    local host="$1"; shift
    ssh -o ConnectTimeout=15 -o BatchMode=yes "${SSH_USER}@${host}" "$@"
}

# -----------------------------------------------------------------------------
# Service control
# -----------------------------------------------------------------------------
stop_services() {
    local host="$1"
    # Convert space-separated string to array
    read -ra svcs <<< "$STOP_SERVICES"

    if "$DRY_RUN"; then
        log_info "[DRY RUN] Would stop on ${host}: ${STOP_SERVICES}"
        return 0
    fi

    log_info "Stopping services on ${host} (${STOP_SERVICES}) ..."
    local svc
    for svc in "${svcs[@]}"; do
        if _ssh "$host" "sudo systemctl stop ${svc}" 2>/dev/null; then
            log_info "  Stopped: ${svc}"
        else
            log_warn "  Could not stop ${svc} on ${host} (may not be running)"
        fi
    done

    _TRAP_NODE="$host"
    _TRAP_SERVICES_STOPPED=true
}

start_services() {
    local host="$1"
    # Restart in reverse stop order
    read -ra svcs <<< "$STOP_SERVICES"
    local reversed=()
    for (( i=${#svcs[@]}-1; i>=0; i-- )); do
        reversed+=( "${svcs[$i]}" )
    done
    local restart_list="${reversed[*]}"

    if "$DRY_RUN"; then
        log_info "[DRY RUN] Would start on ${host}: ${restart_list}"
        _TRAP_SERVICES_STOPPED=false
        _TRAP_NODE=""
        return 0
    fi

    log_info "Starting services on ${host} (${restart_list}) ..."
    local svc
    for svc in "${reversed[@]}"; do
        if _ssh "$host" "sudo systemctl start ${svc}" 2>/dev/null; then
            log_info "  Started: ${svc}"
        else
            log_warn "  Could not start ${svc} on ${host}"
        fi
    done

    # Clear trap state — services are back up
    _TRAP_SERVICES_STOPPED=false
    _TRAP_NODE=""
}

# -----------------------------------------------------------------------------
# Cleanup trap — ensures services are restarted if the script is interrupted
# -----------------------------------------------------------------------------
_cleanup() {
    if "$_TRAP_SERVICES_STOPPED" && [[ -n "$_TRAP_NODE" ]]; then
        log_warn "Script interrupted — restarting services on ${_TRAP_NODE}"
        start_services "$_TRAP_NODE"
    fi

    _stop_progress_heartbeat

    if [[ -n "${CURRENT_RUN_ID:-}" ]]; then
        local duration=$(( $(date +%s) - ${CURRENT_JOB_START_EPOCH:-$(date +%s)} ))
        jabs_event --event-type "backup_complete" --status "stopped" --stage "Stopped" \
            --message "${CURRENT_JOB_NAME} imaging interrupted by script termination (resumes next run)" \
            --run-id "${CURRENT_RUN_ID}" --job-name "${CURRENT_JOB_NAME}" \
            --target-id "${CURRENT_TARGET_ID}" --target-label "${CURRENT_TARGET_LABEL}" \
            --backup-type "Image" --duration-seconds "${duration}" \
            --files-backed-up 0 --bytes-backed-up 0 \
            --error-message "${CURRENT_JOB_NAME} imaging interrupted by script termination (resumes next run)"
        CURRENT_RUN_ID=""
    fi
}
trap _cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# JABS agent monitoring
# -----------------------------------------------------------------------------
# Reports each node's imaging run to a JABS dashboard's Agent Monitoring API
# (see AGENTS_API_GUIDE.md in the jabs-dashboard repo). Disabled entirely
# when JABS_DASHBOARD_URL is empty.
#
# JOB_NAME (configurable via dns_backup.conf) is shared across both nodes
# for the whole run; each node's host (DNS1_HOST/DNS2_HOST) is reported as
# that job's target_id/target_label instead — imaging runs aren't dated
# sub-jobs of a target, so a timestamp in target_id/label would just create
# a new, needless target per run in the dashboard's UI.
#
# The dashboard purges its own job records per its own retention policy
# (see the dashboard's README.md Retention Purge section); IMAGE_RETENTION_DAYS
# above only controls this script's own local image files, independent of
# the dashboard's copy of the data. cleanup_old_images() below reports each
# deleted image's filename to the dashboard via jabs_purge so the matching
# run's status flips to "purged" without deleting the dashboard's record.

jabs_enabled() { [[ -n "${JABS_DASHBOARD_URL}" ]]; }

# generate_uuid  →  prints a UUID (for run_id). Only called when JABS is
# enabled, so python3's availability has already been confirmed by then.
generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || date +%s%N
    fi
}

# jabs_event [--flag value]...
# Thin wrapper around jabs_client.py's `event` subcommand. Fire-and-forget:
# no-op when JABS is disabled; sent even during --dry-run so the dashboard
# API can be exercised without a real imaging run (the --message is tagged
# "[DRY RUN]" so it's obvious on the dashboard). Any failure (bad response,
# network error, missing python3) is logged as a warning and never aborts the
# calling backup. Extra args are passed straight through to jabs_client.py —
# see its --help for the full list of event fields.
jabs_event() {
    jabs_enabled || return 0

    local args=("$@")
    if "$DRY_RUN"; then
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "--message" ]]; then
                args[i + 1]="[DRY RUN] ${args[$(( i + 1 ))]}"
                break
            fi
        done
    fi

    local output
    if ! output="$(python3 "${JABS_CLIENT}" event \
            --server-url "${JABS_DASHBOARD_URL}" \
            --agent-key "${JABS_AGENT_KEY}" \
            --version "${JABS_AGENT_VERSION}" \
            --agent-type "DNS Backup" \
            --timeout "${JABS_TIMEOUT}" \
            "${args[@]}" 2>&1)"; then
        log_warn "JABS event failed to send: ${output}"
        return 0
    fi
    return 0
}

# jabs_purge --target-id ID --external-id ID1 [--external-id ID2 ...] [--message M]
# Thin wrapper around jabs_client.py's `purge` subcommand. Fire-and-forget,
# same semantics as jabs_event (no-op when JABS is disabled, failures logged
# as warnings and never abort the caller). Call right after deleting local
# artifact(s) previously reported via --external-id on a backup_complete event.
jabs_purge() {
    jabs_enabled || return 0

    local output
    if ! output="$(python3 "${JABS_CLIENT}" purge \
            --server-url "${JABS_DASHBOARD_URL}" \
            --agent-key "${JABS_AGENT_KEY}" \
            --timeout "${JABS_TIMEOUT}" \
            "$@" 2>&1)"; then
        log_warn "JABS purge failed to send: ${output}"
        return 0
    fi
    return 0
}

# _start_progress_heartbeat run_id job_name target_id target_label start_epoch
# Launches a background loop sending a heartbeat every JABS_PROGRESS_INTERVAL
# seconds while a long dd/gzip pipeline runs, so the dashboard shows the job
# as alive rather than going quiet between the start and completion events.
_start_progress_heartbeat() {
    local run_id="$1" job_name="$2" target_id="$3" target_label="$4" start_epoch="$5"
    jabs_enabled || return 0

    (
        while sleep "${JABS_PROGRESS_INTERVAL}"; do
            local elapsed=$(( $(date +%s) - start_epoch ))
            jabs_event --event-type "heartbeat" --stage "Imaging in progress" \
                --message "${job_name}: still imaging (${elapsed}s elapsed)" \
                --run-id "${run_id}" --job-name "${job_name}" \
                --target-id "${target_id}" --target-label "${target_label}" \
                --backup-type "Image"
        done
    ) &
    JABS_PROGRESS_PID=$!
    disown "${JABS_PROGRESS_PID}" 2>/dev/null || true
}

# Stops the background loop started by _start_progress_heartbeat, if any.
# Safe to call even if none is running (e.g. JABS disabled or --dry-run).
_stop_progress_heartbeat() {
    if [[ -n "${JABS_PROGRESS_PID}" ]]; then
        kill "${JABS_PROGRESS_PID}" 2>/dev/null || true
        wait "${JABS_PROGRESS_PID}" 2>/dev/null || true
        JABS_PROGRESS_PID=""
    fi
}

# parse_dd_progress_line LINE  →  prints "BYTES_DONE BYTES_PER_SEC" on a
# match, or returns 1 on a non-matching line. Matches GNU dd's
# `status=progress` periodic line, e.g.:
#   "5292277248 bytes (5.3 GB, 4.9 GiB) copied, 5 s, 1.1 GB/s"
# dd's rate unit is decimal/SI (kB=1000, not 1024), unlike rsync's.
parse_dd_progress_line() {
    local line="$1"
    if [[ "${line}" =~ ^([0-9]+)\ bytes.*copied,\ [0-9.]+\ s,\ ([0-9.]+)\ ([A-Za-z]+)/s ]]; then
        local bytes_done="${BASH_REMATCH[1]}"
        local rate_value="${BASH_REMATCH[2]}"
        local rate_unit="${BASH_REMATCH[3]}"
        local mult=1
        case "${rate_unit}" in
            kB|KB) mult=1000 ;;
            MB) mult=1000000 ;;
            GB) mult=1000000000 ;;
            TB) mult=1000000000000 ;;
        esac
        local bps
        bps="$(echo "scale=0; (${rate_value}*${mult})/1" | bc)"
        echo "${bytes_done} ${bps}"
        return 0
    fi
    return 1
}

# watch_dd_progress RUN_ID JOB_NAME TARGET_ID  →  reads dd's status=progress
# lines from stdin (after \r→\n translation), throttling both the local log
# and the JABS progress POST to ~JABS_DD_PROGRESS_INTERVAL wall-clock seconds
# (no percent/ETA available for a raw block device copy, so there's no
# decile-based throttle here, unlike the other agents). Best-effort: a parse
# miss on any line is just skipped.
watch_dd_progress() {
    local run_id="$1" job_name="$2" target_id="$3"
    local last_post=0 line parsed bytes_done bps now
    while IFS= read -r line; do
        parsed="$(parse_dd_progress_line "${line}")" || continue
        bytes_done="${parsed%% *}"
        bps="${parsed##* }"
        now="$(date +%s)"
        if (( now - last_post >= JABS_DD_PROGRESS_INTERVAL )); then
            last_post=${now}
            log_info "Imaging ${target_id}: ${bytes_done} bytes copied (${bps} B/s)"
            jabs_event --event-type "heartbeat" --stage "Imaging in progress" \
                --message "Imaging ${target_id} in progress" \
                --run-id "${run_id}" --job-name "${job_name}" --target-id "${target_id}" \
                --backup-type "Image" \
                --bytes-backed-up "${bytes_done}" --bytes-per-second "${bps}"
        fi
    done
}

# -----------------------------------------------------------------------------
# Image a single node
# -----------------------------------------------------------------------------
image_node() {
    local host="$1"
    local node_name="$2"
    local job_name="${JOB_NAME}"
    local outdir="${BACKUP_BASE_DIR}/${host}"
    local outfile="${outdir}/sd_image_${TIMESTAMP}.img.gz"

    log_info "========================================"
    log_info "Imaging node: ${host}"
    log_info "  Source:      ${host}:${SD_DEVICE}"
    log_info "  Destination: ${outfile}"
    log_info "========================================"

    if ! "$DRY_RUN"; then
        mkdir -p "$outdir" || { log_error "Cannot create directory: ${outdir}"; return 1; }
    fi

    # ── JABS: one run_id/job target per node per run (a new dated image) ──
    # job_name (JOB_NAME) is shared across both nodes for the whole run; the
    # target is node_name (DNS1/DNS2), stable even if DNS1_HOST/DNS2_HOST
    # (the IP/hostname used for SSH) changes.
    local run_id=""
    jabs_enabled && run_id="$(generate_uuid)"
    local target_id="${node_name}"
    local target_label="${node_name}"

    # Track this job as "in flight" so the EXIT trap can finalize it as
    # "stopped" if the script is interrupted before we reach one of the
    # normal completion points below (cleared right before every return).
    if jabs_enabled; then
        CURRENT_RUN_ID="${run_id}"
        CURRENT_JOB_NAME="${job_name}"
        CURRENT_TARGET_ID="${target_id}"
        CURRENT_TARGET_LABEL="${target_label}"
        CURRENT_JOB_START_EPOCH="$(date +%s)"
    fi

    jabs_event \
        --event-type "heartbeat" \
        --message "Starting SD image: ${host}" \
        --stage "Starting image" \
        --run-id "${run_id}" \
        --job-run-id "${JOB_RUN_ID}" \
        --job-name "${job_name}" \
        --backup-type "Image" \
        --target-id "${target_id}" \
        --target-label "${target_label}" \
        --source "${host}:${SD_DEVICE}" \
        --destination "${outfile}"

    stop_services "$host"

    log_info "Waiting ${FAILOVER_WAIT}s for keepalived VIP failover to peer ..."
    "$DRY_RUN" || sleep "$FAILOVER_WAIT"

    log_info "Starting SD card image — this will take a while ..."
    local imaging_failed=false
    local image_start_epoch
    image_start_epoch="$(date +%s)"

    _start_progress_heartbeat "${run_id}" "${host}" "${target_id}" "${target_label}" "${image_start_epoch}"

    if "$DRY_RUN"; then
        log_info "[DRY RUN] Would run: ssh ${SSH_USER}@${host} 'sudo dd if=${SD_DEVICE} bs=4M 2>/dev/null' | gzip > ${outfile}"
    else
        local tmp_file="${outfile}.tmp"
        local dd_ok=false
        if jabs_enabled; then
            if _ssh "$host" "sudo dd if=${SD_DEVICE} bs=4M status=progress" \
                    2> >(stdbuf -oL tr '\r' '\n' | watch_dd_progress "${run_id}" "${job_name}" "${target_id}") \
                    | gzip > "$tmp_file"; then
                dd_ok=true
            fi
            wait
        else
            if _ssh "$host" "sudo dd if=${SD_DEVICE} bs=4M 2>/dev/null" | gzip > "$tmp_file"; then
                dd_ok=true
            fi
        fi
        if "$dd_ok"; then
            mv "$tmp_file" "$outfile"
            chmod 600 "$outfile"
            local size
            size=$(du -sh "$outfile" | cut -f1)
            log_info "Image saved: $(basename "$outfile") (${size})"
        else
            log_error "dd/gzip pipeline failed for ${host}"
            rm -f "$tmp_file"
            imaging_failed=true
        fi
    fi

    _stop_progress_heartbeat

    start_services "$host"

    local duration=$(( $(date +%s) - image_start_epoch ))

    if "$imaging_failed"; then
        jabs_event --event-type "error" --status "failed" \
            --message "SD image failed: ${host}" --stage "Error" \
            --run-id "${run_id}" --job-name "${job_name}" --target-id "${target_id}" \
            --target-label "${target_label}" --backup-type "Image" \
            --duration-seconds "${duration}" \
            --error-message "dd/gzip pipeline failed for ${host}"
        CURRENT_RUN_ID=""
        return 1
    fi

    local bytes_backed_up=0
    "$DRY_RUN" || bytes_backed_up="$(stat -c%s "$outfile" 2>/dev/null || echo 0)"
    jabs_event --event-type "backup_complete" --status "success" \
        --message "SD image complete" --stage "Completed" \
        --run-id "${run_id}" --job-name "${job_name}" --target-id "${target_id}" \
        --target-label "${target_label}" --backup-type "Image" \
        --duration-seconds "${duration}" \
        --files-backed-up 1 --bytes-backed-up "${bytes_backed_up}" \
        --external-id "$(basename "$outfile")"
    CURRENT_RUN_ID=""

    log_info "Waiting ${REJOIN_WAIT}s for ${host} to fully rejoin before imaging peer ..."
    "$DRY_RUN" || sleep "$REJOIN_WAIT"

    return 0
}

# -----------------------------------------------------------------------------
# Remove old image files
# -----------------------------------------------------------------------------
cleanup_old_images() {
    if (( IMAGE_RETENTION_DAYS == 0 )); then
        return 0
    fi

    log_info "--- Cleanup: removing images older than ${IMAGE_RETENTION_DAYS} days ---"

    local host removed=0
    for host in "$DNS1_HOST" "$DNS2_HOST"; do
        local dir="${BACKUP_BASE_DIR}/${host}"
        [[ -d "$dir" ]] || continue

        if "$DRY_RUN"; then
            local count
            count=$(find "$dir" -maxdepth 1 -name 'sd_image_*.img.gz' \
                -mtime "+${IMAGE_RETENTION_DAYS}" 2>/dev/null | wc -l)
            log_info "[DRY RUN] Would remove ${count} image(s) older than ${IMAGE_RETENTION_DAYS} days from ${dir}"
            continue
        fi

        local -a purged_names=()
        while IFS= read -r -d '' old_file; do
            log_info "Removing old image: ${old_file}"
            rm -f "$old_file"
            purged_names+=("$(basename "$old_file")")
            (( removed++ )) || true
        done < <(find "$dir" -maxdepth 1 -name 'sd_image_*.img.gz' \
                     -mtime "+${IMAGE_RETENTION_DAYS}" -print0 2>/dev/null)

        if (( ${#purged_names[@]} > 0 )); then
            local -a purge_args=(--target-id "${host}")
            local name
            for name in "${purged_names[@]}"; do
                purge_args+=(--external-id "${name}")
            done
            jabs_purge "${purge_args[@]}" \
                --message "Removed ${#purged_names[@]} image(s) older than ${IMAGE_RETENTION_DAYS} days"
        fi
    done

    if (( removed > 0 )); then
        log_info "Removed ${removed} old image(s)"
    else
        "$DRY_RUN" || log_info "No old images to remove"
    fi

    # Scrub old run logs on the same schedule as the images they document.
    if "$DRY_RUN"; then
        local log_count
        log_count=$(find "$LOG_DIR" -maxdepth 1 -name 'sd_image_backup_*.log' \
            -mtime "+${IMAGE_RETENTION_DAYS}" 2>/dev/null | wc -l)
        log_info "[DRY RUN] Would remove ${log_count} log file(s) older than ${IMAGE_RETENTION_DAYS} days from ${LOG_DIR}"
        return 0
    fi

    local removed_logs=0
    while IFS= read -r -d '' old_log; do
        [[ "$old_log" == "$LOG_FILE" ]] && continue  # never delete the log of the run currently writing it
        log_info "Removing old log: ${old_log}"
        rm -f "$old_log"
        (( removed_logs++ )) || true
    done < <(find "$LOG_DIR" -maxdepth 1 -name 'sd_image_backup_*.log' \
                 -mtime "+${IMAGE_RETENTION_DAYS}" -print0 2>/dev/null)

    if (( removed_logs > 0 )); then
        log_info "Removed ${removed_logs} old log file(s)"
    fi
}

# -----------------------------------------------------------------------------
# Usage / help
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Creates compressed SD card images of both HA DNS nodes via SSH, written to
the NAS. Services are stopped on each node before imaging (keepalived hands
the VIP to the peer for zero downtime) and restarted after.

Run from your workstation. Requires SSH key-based auth with passwordless
sudo for 'dd' and 'systemctl' on each node. See README for setup.

Options:
  --dry-run    Show what would be done without creating images
  --help       Show this help message

Configuration is read from dns_backup.conf in the same directory as this script.
Images are written to: ${BACKUP_BASE_DIR}/<node>/sd_image_<timestamp>.img.gz

To restore a node from an image:
  gunzip -c <image.img.gz> | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
preflight_checks() {
    log_info "DNS1: ${DNS1_HOST}   DNS2: ${DNS2_HOST}"
    log_info "SSH user: ${SSH_USER}   SD device: ${SD_DEVICE}"
    log_info "Backup base: ${BACKUP_BASE_DIR}"

    if jabs_enabled; then
        command -v python3 &>/dev/null || die "JABS_DASHBOARD_URL is set but python3 is not installed"
        command -v stdbuf &>/dev/null || die "JABS_DASHBOARD_URL is set but stdbuf is not installed (required for progress reporting)"
        [[ -f "${JABS_CLIENT}" ]] || die "JABS_DASHBOARD_URL is set but ${JABS_CLIENT} is missing"
        [[ -z "${JABS_AGENT_KEY}" ]] && die "JABS_DASHBOARD_URL is set but JABS_AGENT_KEY is empty — register this agent on the dashboard's Agents page and set its API key"
    fi

    if "$DRY_RUN"; then
        return 0
    fi

    # NAS mount
    mountpoint -q "$NAS_MOUNT" || die "NAS mount ${NAS_MOUNT} is not mounted — aborting"
    [[ -w "$NAS_MOUNT" ]]      || die "NAS mount ${NAS_MOUNT} is not writable — aborting"

    # SSH connectivity (BatchMode=yes ensures we fail fast if keys aren't set up)
    local host
    for host in "$DNS1_HOST" "$DNS2_HOST"; do
        if ! _ssh "$host" true 2>/dev/null; then
            die "Cannot SSH to ${host} as ${SSH_USER} without a password prompt.
  Set up SSH key authentication first:
    ssh-copy-id ${SSH_USER}@${host}
  Then ensure passwordless sudo for dd and systemctl on ${host}:
    echo '${SSH_USER} ALL=(ALL) NOPASSWD: /usr/bin/dd, /usr/bin/systemctl' | sudo tee /etc/sudoers.d/sd_image_backup"
        fi
        log_info "SSH OK: ${host}"
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --help|-h) usage ;;
            *) die "Unknown argument: ${arg}. Use --help for usage." ;;
        esac
    done

    # Ensure log directory exists before first log_info call
    if ! "$DRY_RUN"; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    fi

    log_info "========================================================"
    log_info "dns_backup.sh started"
    "$DRY_RUN" && log_info "(dry-run mode — no files will be written)"
    log_info "========================================================"

    preflight_checks

    # ── JABS — bare heartbeat ──────────────────────────────────────────────
    # No event_type/target_id → server just records host online + version,
    # without touching any backup job. Sent once per run regardless of
    # whether either node ends up imaging successfully. JOB_CRON (if set)
    # reports this script's crontab schedule for the dashboard's "Next
    # Event" column.
    jabs_event --message "dns_backup run started" --job-name "${JOB_NAME}" --cron-schedule "${JOB_CRON}"

    # One ID shared by both DNS1/DNS2 nodes imaged in this invocation,
    # distinct from each node's own run_id — lets the dashboard group both
    # nodes into a single "job run" and use its earliest start, not either
    # node's individually.
    JOB_RUN_ID="$(generate_uuid)"

    if image_node "$DNS1_HOST" "DNS1"; then
        log_info "Node ${DNS1_HOST}: image complete"
    else
        log_error "Node ${DNS1_HOST}: image FAILED"
        (( ERRORS++ )) || true
    fi

    jabs_event --message "${DNS1_HOST} finished — starting ${DNS2_HOST}"

    if image_node "$DNS2_HOST" "DNS2"; then
        log_info "Node ${DNS2_HOST}: image complete"
    else
        log_error "Node ${DNS2_HOST}: image FAILED"
        (( ERRORS++ )) || true
    fi

    cleanup_old_images

    jabs_event --message "dns_backup run finished (${ERRORS} failure(s))"

    log_info "========================================================"
    if (( ERRORS == 0 )); then
        log_info "All SD image backups completed successfully"
        log_info "Log: ${LOG_FILE}"
    else
        log_warn "Completed with ${ERRORS} failure(s) — review log: ${LOG_FILE}"
    fi
    log_info "========================================================"

    (( ERRORS == 0 ))
}

main "$@"
