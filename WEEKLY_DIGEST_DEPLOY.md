# weekly_smart_digest.sh — deploy to w2vy

Replaces the 8 rsh-based `~/Claude/weekly_drive_report.sh pveN` entries on `/home/tom`'s crontab. Single weekly entry on w2vy, queries InfluxDB instead of rsh.

## Prerequisites on w2vy

w2vy already has `jq` + `curl` + Node 18. Only `claude` CLI is missing.

```bash
ssh w2vy
sudo npm install -g @anthropic-ai/claude-code
# verify
claude --version
```

The npm-global install lands `claude` at `/usr/local/bin/claude` (in cron's default PATH). If you prefer a per-user install, use `npm install -g --prefix=$HOME/.local` and set `PATH=$HOME/.local/bin:$PATH` in the crontab line.

First-run `claude` interactively once to log in / accept TOS, otherwise the cron run will hang on auth.

## Files to copy

From workstation:

```bash
scp ~/Claude/monitoring-stack/weekly_smart_digest.sh w2vy:/root/scripts/
scp ~/Claude/drive_health/baselines.json w2vy:/root/monitoring-stack/baselines.json
ssh w2vy 'chmod +x /root/scripts/weekly_smart_digest.sh'
```

`/root/monitoring-stack/` already exists on w2vy (mirror of `~/Claude/monitoring-stack/`). The `baselines.json` lives separately so the deploy artifacts in `monitoring-stack/` stay reusable.

## Smoke test (no token cost, no claude call)

The script saves the raw payload to `$REPORT_DIR/digest_*.payload.txt` before invoking claude. Force the claude check to fail by running with a stripped PATH, inspect the payload:

```bash
ssh w2vy 'REPORT_DIR=/tmp/digest_test PATH=/usr/bin:/bin /root/scripts/weekly_smart_digest.sh pve20'
# expect: "ERROR: claude CLI not found in PATH; raw payload saved to /tmp/digest_test/..."
ssh w2vy 'cat /tmp/digest_test/*.payload.txt | head -100'
```

Verify the per-host data block shows CSV rows (not empty fences). If empty: check `INFLUX_URL` reaches the DB, and that the SMART measurement has data for that host in the last 24h / 7d.

## First real run

```bash
ssh w2vy '/root/scripts/weekly_smart_digest.sh'
ssh w2vy 'cat /root/drive_health_reports/digest_latest.md'
```

Expect a digest like the current `weekly_drive_report.sh` output — severity buckets per drive per host.

## Cron entry on w2vy

Use root's user crontab (visible to `crontab -l`, matches the `/home/tom` pattern). Avoid `/etc/cron.d/` — invisible to `crontab -l` and easy to forget.

```bash
# as root on w2vy
crontab -e
```

Paste:
```cron
0 2 * * 4 /root/scripts/weekly_smart_digest.sh >>/var/log/smart-digest.log 2>&1
```

Thursdays 02:00, matches the old workstation cadence. Reports land in `/root/drive_health_reports/`.

If you want digest output mailed: pipe `digest_latest.md` to `mail -s "SMART weekly digest" tom@moltentech.us` after the script call.

## After ONE good Thursday run — decommission the 8 workstation entries

These are the current `/home/tom` crontab lines to remove (verified 2026-05-14):

```cron
0 2 * * 4 ~/Claude/weekly_drive_report.sh pve20
5 2 * * 4 ~/Claude/weekly_drive_report.sh pve50
10 2 * * 4 ~/Claude/weekly_drive_report.sh pve60
15 2 * * 4 ~/Claude/weekly_drive_report.sh pve35
20 2 * * 4 ~/Claude/weekly_drive_report.sh pve45
25 2 * * 4 ~/Claude/weekly_drive_report.sh pve65
30 2 * * 4 ~/Claude/weekly_drive_report.sh pve40
35 2 * * 4 ~/Claude/weekly_drive_report.sh pve55
```

`crontab -e` and delete the eight lines. `~/Claude/weekly_drive_report.sh` + `analyze_drive_health.sh` + `collect_drive_health_*.sh` stay on disk as reference implementations.

## Known gaps (Layer 1 issues, not script bugs)

- **pve55 SAS drives**: telegraf only exposes `exit_status`/`health_ok`/`temp_c` (`smart_device`) + `Temperature_Celsius`/`Load_Cycle_Count`/`Start_Stop_Count` (`smart_attribute`). SCSI grown-defects, uncorrected-errors, non-medium-errors are NOT captured. Baselines.json has these values but nothing to compare against. Fix is upstream (telegraf SAS-specific config), separate from Layer 2.
- **Desktops (pve35/45/50/60/65)**: currently offline per memory, so SMART data won't appear in InfluxDB until each is back online and telegraf [[inputs.smart]] deployed via `deploy_host_smart.sh`. The digest will simply not include offline hosts in the auto-discovery output.

## Configurable env vars

| Var | Default | Notes |
|---|---|---|
| `INFLUX_URL` | `http://localhost:8086` | w2vy is the DB host, default works |
| `INFLUX_ORG` | `moltentech` | |
| `INFLUX_BUCKET` | `monitoring` | |
| `INFLUX_TOKEN` | **required, no default** | sourced from `monitoring-stack/.env` when the script runs in-tree; otherwise export it before invocation |
| `REPORT_DIR` | `/root/drive_health_reports` | |
| `BASELINES_FILE` | `/root/monitoring-stack/baselines.json` | |
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Sonnet is plenty for CSV summarization; Opus 4.7 is overkill. Override to `claude-opus-4-7` if you want richer analysis. |
