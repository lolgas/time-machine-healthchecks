#!/usr/bin/env bash
#
# time-machine-healthchecks.sh
# Poll macOS's unified log for Time Machine BackupDispatching events,
# decide whether the most recent backup succeeded recently enough, and
# report state to healthchecks.io.
#
# Why log-stream parsing and not `tmutil latestbackup`: tmutil's
# latestbackup subcommand requires Full Disk Access for the calling
# process. Granting FDA to /usr/sbin/cron is broader than necessary
# just to read a timestamp. Reading the unified log for the public
# "Backup succeeded" / "Backup failed" lines doesn't require it.
#
# The relevant log markers (macOS Sequoia, backupd subsystem
# com.apple.TimeMachine, category BackupDispatching) are:
#   "Backup requested to ... destination in rotation"  — start
#   "Backup succeeded"                                 — success
#   "Backup failed"                                    — failure
# A normal backup logs one "requested" and one "succeeded" within ~30s.
#
# Requirements:
#   bash, /usr/bin/python3 (parses config.json), /usr/bin/log (stock).
#
# Logging:
#   The script echoes to stdout. Schedule it from cron with output
#   redirected to the log file, e.g.:
#     0 * * * * /path/to/time-machine-healthchecks/time-machine-healthchecks.sh \
#         >> /path/to/time-machine-healthchecks/time-machine-healthchecks.log 2>&1
#   On exit, the trap tails the last 100KB of that log file and posts
#   it to healthchecks.io as the ping body.
#
# Exit codes (also used as the healthchecks.io ping suffix via $HC_URL/$rc):
#   0  latest backup succeeded recently OR a backup is currently running
#   1  latest event was a failure, or last success is older than stale threshold
#   2  infrastructure error (missing config, log query failed)

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.json"
LOG="$SCRIPT_DIR/time-machine-healthchecks.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ================================================================
# Config
# ================================================================
if [ ! -f "$CONFIG" ]; then
    log "ERROR: config file not found: $CONFIG"
    log "Copy config.example.json to config.json and fill in your healthcheck UUID."
    exit 2
fi

read_cfg() {
    /usr/bin/python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
v = cfg.get(sys.argv[2])
if v is None:
    sys.exit(0)
print(v)
' "$CONFIG" "$1"
}

HC_UUID=$(read_cfg "healthcheck_uuid")
STALE_HOURS=$(read_cfg "stale_after_hours")
LOOKBACK_HOURS=$(read_cfg "log_lookback_hours")

if [ -z "$HC_UUID" ] || [ -z "$STALE_HOURS" ] || [ -z "$LOOKBACK_HOURS" ]; then
    log "ERROR: config missing required keys (healthcheck_uuid, stale_after_hours, log_lookback_hours)"
    exit 2
fi
HC_URL="https://hc-ping.com/$HC_UUID"

# Allow a fresh "Backup requested" to count as "in progress" for this
# long after it appears (no result yet). Prevents flapping when a run
# is genuinely long.
IN_PROGRESS_GRACE_SEC=$((45 * 60))

# ================================================================
# Healthchecks.io ping setup
# ================================================================
curl -fsS -m 10 --retry 5 --retry-delay 2 -o /dev/null "$HC_URL/start" || true
trap 'rc=$?; tail -c 100000 "$LOG" 2>/dev/null | curl -fsS -m 10 --retry 5 --retry-delay 2 --data-binary @- -o /dev/null "$HC_URL/$rc" || true' EXIT

log "=== Time Machine monitor starting ==="
log "Stale threshold: ${STALE_HOURS}h; log lookback: ${LOOKBACK_HOURS}h"

# ================================================================
# Pull TM events from unified log
# ================================================================
# We only need three lines per backup: the request, the success, the
# failure. Filtering with grep after the fact is simpler than nesting
# AND/OR clauses in the log predicate, and the output volume is small.
log_out=$(/usr/bin/log show \
        --info \
        --predicate 'subsystem == "com.apple.TimeMachine"' \
        --last "${LOOKBACK_HOURS}h" \
        --style compact 2>/dev/null \
    | grep -E 'BackupDispatching\] Backup (requested|succeeded|failed)')

if [ -z "$log_out" ]; then
    log "ERROR: no TM BackupDispatching events found in last ${LOOKBACK_HOURS}h"
    log "Either TM hasn't run in that window or the log predicate has stopped matching."
    exit 1
fi

event_count=$(printf '%s\n' "$log_out" | wc -l | tr -d ' ')
log "Found $event_count BackupDispatching event(s)"

# ================================================================
# Identify the most recent of each event type
# ================================================================
latest_success=$(printf '%s\n' "$log_out" | grep 'Backup succeeded' | tail -1 || true)
latest_fail=$(printf    '%s\n' "$log_out" | grep 'Backup failed'    | tail -1 || true)
latest_request=$(printf '%s\n' "$log_out" | grep 'Backup requested' | tail -1 || true)

# Pull the timestamp off the front: "2026-05-11 15:07:27.872 I  backupd[...] ..."
extract_ts() {
    [ -z "$1" ] && return 0
    printf '%s' "$1" | awk '{print $1, $2}'
}

# macOS date(1): parse "YYYY-MM-DD HH:MM:SS" → epoch seconds. Drops the
# fractional part because date -j -f doesn't accept %N.
to_epoch() {
    [ -z "$1" ] && { echo 0; return; }
    local clean
    clean=$(printf '%s' "$1" | cut -d. -f1)
    /bin/date -j -f "%Y-%m-%d %H:%M:%S" "$clean" "+%s" 2>/dev/null || echo 0
}

ts_success=$(extract_ts "$latest_success")
ts_fail=$(extract_ts    "$latest_fail")
ts_request=$(extract_ts "$latest_request")

e_success=$(to_epoch "$ts_success")
e_fail=$(to_epoch    "$ts_fail")
e_request=$(to_epoch "$ts_request")
now=$(/bin/date +%s)

log "Latest success: ${ts_success:-<none in window>}"
log "Latest failure: ${ts_fail:-<none in window>}"
log "Latest request: ${ts_request:-<none in window>}"

# ================================================================
# Decide state
# ================================================================
stale_sec=$((STALE_HOURS * 3600))
state="unknown"
state_reason=""

if [ "$e_fail" -gt "$e_success" ] && [ "$e_fail" -gt 0 ]; then
    state="failed"
    state_reason="latest event is a failure at $ts_fail (most recent success: ${ts_success:-none})"
elif [ "$e_success" -gt 0 ]; then
    age=$((now - e_success))
    age_min=$((age / 60))
    age_h_decimal=$(awk -v a="$age" 'BEGIN { printf "%.1f", a/3600 }')

    if [ "$age" -lt "$stale_sec" ]; then
        state="ok"
        state_reason="last success at $ts_success (age ${age_min}m / ${age_h_decimal}h)"
    elif [ "$e_request" -gt "$e_success" ] && [ $((now - e_request)) -lt "$IN_PROGRESS_GRACE_SEC" ]; then
        state="ok-in-progress"
        state_reason="last success at $ts_success is ${age_h_decimal}h ago, but a backup is in progress (requested at $ts_request)"
    else
        state="stale"
        state_reason="last success at $ts_success is ${age_h_decimal}h ago (stale threshold ${STALE_HOURS}h) and no backup in progress"
    fi
else
    state="no-success"
    state_reason="no successful backup found in last ${LOOKBACK_HOURS}h"
fi

log ""
log "State: $state"
log "Reason: $state_reason"

# ================================================================
# Body: recent events for the HC ping log
# ================================================================
log ""
log "Recent events (last 20):"
printf '%s\n' "$log_out" | tail -20 | while IFS= read -r line; do
    log "  $line"
done

# ================================================================
# Outcome (the EXIT trap handles the HC ping based on the exit code)
# ================================================================
case "$state" in
    ok|ok-in-progress)
        log "=== Run complete: OK ==="
        exit 0
        ;;
    *)
        log "=== Run complete: FAIL ($state) ==="
        exit 1
        ;;
esac
