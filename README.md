# time-machine-healthchecks

A small macOS shell script that monitors Time Machine and reports state to [healthchecks.io](https://healthchecks.io) — without requiring Full Disk Access.

## Why

The obvious way to check Time Machine's last successful backup is `tmutil latestbackup`. That command requires Full Disk Access for the calling process — and granting FDA to `/usr/sbin/cron` is much broader than necessary just to read a timestamp.

This script reads the same information out of macOS's unified log instead. The events it cares about (`subsystem == "com.apple.TimeMachine"`, category `BackupDispatching`) are public-level log messages, so `log show` returns them without FDA.

## What it does

On each run, the script:

1. Queries `log show` for Time Machine `BackupDispatching` events in the last `log_lookback_hours`.
2. Identifies the most recent of each event type: `Backup requested`, `Backup succeeded`, `Backup failed`.
3. Classifies the current state:
   - **ok** — latest success is within `stale_after_hours`
   - **ok-in-progress** — last success is older than the threshold, but a `Backup requested` appeared within the last 45 min with no result yet (long backup in progress)
   - **stale** — last success is older than the threshold and no backup is in progress
   - **failed** — latest event is a `Backup failed`
   - **no-success** — no successful backup found in the lookback window
4. Pings healthchecks.io with the exit code as the URL suffix (`/0` for OK, `/1` for failures). The ping body is the tail of the script's log file — current state, reason, and a recent event timeline.

## Requirements

- macOS (developed against Sequoia / Darwin 25.x)
- `bash`, `/usr/bin/python3`, `/usr/bin/log`, `/bin/date` — all stock
- A [healthchecks.io](https://healthchecks.io) account (free tier is fine) and a check UUID

## Install

```sh
git clone https://github.com/lolgas/time-machine-healthchecks.git
cd time-machine-healthchecks
cp config.example.json config.json
# Edit config.json: set healthcheck_uuid, tune thresholds if needed.
chmod 700 time-machine-healthchecks.sh
chmod 600 config.json
```

Test it manually (run with the same redirect cron will use, so the EXIT trap's HC ping body has this run's output):

```sh
./time-machine-healthchecks.sh >> time-machine-healthchecks.log 2>&1
```

Then add to crontab (`crontab -e`):

```cron
0 * * * * /absolute/path/to/time-machine-healthchecks/time-machine-healthchecks.sh >> /absolute/path/to/time-machine-healthchecks/time-machine-healthchecks.log 2>&1
```

The output redirect is **required** — the script's EXIT trap tails this log file and POSTs the tail to healthchecks.io as the ping body. Without it, HC still receives the success/failure ping but with a stale or empty body.

## Configuration

`config.json` (copy from `config.example.json`):

| Key | Type | Description |
|---|---|---|
| `healthcheck_uuid` | string | Your healthchecks.io check UUID |
| `stale_after_hours` | int | How old the last successful backup can be before alerting. Set this to comfortably exceed your Time Machine schedule — e.g. `3` is a reasonable starting point if you back up hourly and want to tolerate the occasional skip. |
| `log_lookback_hours` | int | How far back `log show` queries for events. `24` is generous and cheap. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Latest backup succeeded recently, or a backup is currently in progress |
| 1 | Latest event was a failure, or last success is older than the stale threshold |
| 2 | Infrastructure error (missing config, log query returned nothing) |

The exit code is appended to the healthchecks.io ping URL, so HC treats `/1` and `/2` as failure pings.

## Recommended healthchecks.io setup

The script always pings HC every run (the body content is the value, not silence detection), so HC's period/grace should match how often you run the cron job.

- **Hourly cron** (`0 * * * *`): HC period `1h`, grace `2h`. HC alerts if the script itself stops running (no ping for ~3h) and on every script-reported failure ping. Backup failures page immediately.
- **Every 15 min** (`*/15 * * * *`): HC period `15m`, grace `15-30m`. Faster detection of a downed script; same failure-ping behavior.

Either works — `stale_after_hours` is what governs how patient the script is about Time Machine itself.

## How it works under the hood

The unified-log markers this script depends on (macOS Sequoia 25.x, `backupd`):

| Log line fragment | Meaning |
|---|---|
| `[com.apple.TimeMachine:BackupDispatching] Backup requested ...` | A new backup attempt is starting |
| `[com.apple.TimeMachine:BackupDispatching] Backup succeeded` | Backup completed successfully |
| `[com.apple.TimeMachine:BackupDispatching] Backup failed` | Backup failed |

These are emitted at the default (non-`private`) log level, so `log show` reads them under cron's default sandbox without elevated privileges. If a future macOS version changes the strings or marks them private, the script will alert (`no events found`) and you'll need to update the predicate or grep.

## License

MIT — see [LICENSE](LICENSE).
