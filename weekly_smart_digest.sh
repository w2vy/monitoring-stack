#!/usr/bin/env bash
# weekly_smart_digest.sh
# InfluxDB-sourced weekly SMART drive-health digest. Runs on w2vy (DB host VM).
# Replaces the 8 rsh-based weekly entries on /home/tom that broke after
# the 2026-04-26 LAN isolation.
#
# Usage:
#   weekly_smart_digest.sh                 # all hosts seen in last 24h
#   weekly_smart_digest.sh pve20 pve40     # explicit host list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
fi

INFLUX_URL="${INFLUX_URL:-http://localhost:8086}"
INFLUX_ORG="${INFLUX_ORG:-moltentech}"
INFLUX_BUCKET="${INFLUX_BUCKET:-monitoring}"
: "${INFLUX_TOKEN:?INFLUX_TOKEN not set (export it or put it in $ENV_FILE)}"

REPORT_DIR="${REPORT_DIR:-$HOME/drive_health_reports}"
BASELINES_FILE="${BASELINES_FILE:-$HOME/monitoring-stack/baselines.json}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

mkdir -p "$REPORT_DIR"
DATESTAMP=$(date +%Y%m%d_%H%M%S)
OUT="$REPORT_DIR/digest_${DATESTAMP}.md"
RAW="$REPORT_DIR/digest_${DATESTAMP}.payload.txt"

flux() {
  curl -sS --fail --max-time 60 \
    -H "Authorization: Token $INFLUX_TOKEN" \
    -H "Accept: application/csv" \
    -H "Content-Type: application/vnd.flux" \
    --data-binary "$1" \
    "$INFLUX_URL/api/v2/query?org=$INFLUX_ORG"
}

if [ $# -gt 0 ]; then
  HOSTS="$*"
else
  HOSTS=$(flux 'import "influxdata/influxdb/schema"
schema.measurementTagValues(bucket: "'"$INFLUX_BUCKET"'", measurement: "smart_device", tag: "host", start: -24h)' \
    | tr -d '\r' \
    | awk -F, 'NR>1 && $4 != "" && $4 !~ /^_/ {print $4}' | sort -u | tr '\n' ' ')
fi

if [ -z "${HOSTS// }" ]; then
  echo "ERROR: no SMART hosts found in InfluxDB (last 24h). Is telegraf [[inputs.smart]] running anywhere?" >&2
  exit 1
fi

build_host_block() {
  local host="$1"

  local device_csv
  device_csv=$(flux "
from(bucket: \"$INFLUX_BUCKET\")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == \"smart_device\" and r.host == \"$host\")
  |> last()
  |> keep(columns: [\"_field\", \"_value\", \"device\", \"model\", \"serial_no\"])
")

  local attr_csv
  attr_csv=$(flux "
attrs = [\"Reallocated_Sector_Ct\", \"Current_Pending_Sector\", \"Offline_Uncorrectable\",
  \"UDMA_CRC_Error_Count\", \"Power_On_Hours\", \"Temperature_Celsius\",
  \"Percent_Lifetime_Remain\", \"Percentage_Used\", \"Media_Wearout_Indicator\",
  \"Wear_Leveling_Count\", \"Total_LBAs_Written\", \"SSD_Life_Left\",
  \"Lifetime_Writes_GiB\", \"SATA_CRC_Error_Count\", \"Unsafe_Shutdowns\",
  \"Power_Cycle_Count\", \"Reported_Uncorrect\", \"Non_Medium_Errors\",
  \"Reallocated_Event_Count\", \"Hardware_ECC_Recovered\"]

base = from(bucket: \"$INFLUX_BUCKET\")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == \"smart_attribute\" and r.host == \"$host\" and r._field == \"raw_value\")
  |> filter(fn: (r) => contains(value: r.name, set: attrs))

last_vals = base |> last() |> map(fn: (r) => ({r with stat: \"last\"}))
first_vals = base |> first() |> map(fn: (r) => ({r with stat: \"first\"}))
max_vals = base |> max() |> map(fn: (r) => ({r with stat: \"max\"}))

union(tables: [last_vals, first_vals, max_vals])
  |> keep(columns: [\"name\", \"stat\", \"_value\", \"device\", \"serial_no\", \"model\"])
")

  cat <<EOF

### Host: $host

#### Device snapshot (last 24h):
\`\`\`csv
$device_csv
\`\`\`

#### Attribute trend (7d, stat = first|last|max):
\`\`\`csv
$attr_csv
\`\`\`
EOF
}

DATA_BLOCKS=""
for host in $HOSTS; do
  echo "querying $host" >&2
  DATA_BLOCKS+=$(build_host_block "$host")
done

BASELINES_CONTEXT=""
if [ -f "$BASELINES_FILE" ]; then
  BASELINES_CONTEXT="

## Pre-existing baselines

Drives below were moved from prior hosts with these pre-existing values. Values at or below baseline are inherited, NOT new failures. Only flag values that have INCREASED beyond baseline.

\`\`\`json
$(cat "$BASELINES_FILE")
\`\`\`
"
fi

PROMPT="You are analyzing a 7-day SMART drive-health window for the moltentech Proxmox cluster.

For each host, produce a section with:
1. One line per drive prefixed with 🔴 CRITICAL (replace now) / ⚠️ SOON (plan replacement) / 👀 MONITOR (watch closely) / ✅ GOOD.
2. Lead with what CHANGED in the last 7 days (delta = last − first; or max for temperature). Do not restate static values that haven't moved.
3. Flag any growth in Reallocated_Sector_Ct, Current_Pending_Sector, Offline_Uncorrectable, Reallocated_Event_Count, Non_Medium_Errors, Reported_Uncorrect.
4. Flag Temperature_Celsius max > 50°C, Percentage_Used > 80, SSD_Life_Left < 20, Percent_Lifetime_Remain raw > 80.
5. Stay within 10 lines per host. Be direct and actionable.
6. If a host's data is missing/empty or every delta is zero, emit '✅ no changes' for that host.
$BASELINES_CONTEXT

## Per-host data
$DATA_BLOCKS
"

printf '%s\n' "$PROMPT" >"$RAW"

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude CLI not found in PATH; raw payload saved to $RAW" >&2
  exit 2
fi

{
  echo "# SMART weekly digest — $(date '+%Y-%m-%d %H:%M %Z')"
  echo
  echo "Hosts: $HOSTS"
  echo
  printf '%s' "$PROMPT" | claude -p --dangerously-skip-permissions --model "$CLAUDE_MODEL"
} >"$OUT"

ln -sf "$(basename "$OUT")" "$REPORT_DIR/digest_latest.md"
echo "wrote $OUT" >&2
