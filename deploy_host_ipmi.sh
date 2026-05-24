#!/bin/bash
# Idempotent per-host telegraf installer for Phase 1 IPMI monitoring.
# Usage: deploy_host_ipmi.sh <hostname> [--no-dcmi]
# Runs from rnode (or any control host), ssh's into <hostname> as root.

set -euo pipefail

HOST="${1:?usage: $0 <hostname> [--no-dcmi]}"
DCMI=1
[ "${2:-}" = "--no-dcmi" ] && DCMI=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_TMPL="$SCRIPT_DIR/telegraf-host-base.conf.tmpl"
IPMI_TMPL="$SCRIPT_DIR/telegraf-host-ipmi.conf.tmpl"
OVERRIDE_FILE="$SCRIPT_DIR/telegraf-root.override.conf"
DCMI_SCRIPT="$SCRIPT_DIR/dcmi_collect.sh"
ENV_FILE="$SCRIPT_DIR/.env"

for f in "$BASE_TMPL" "$IPMI_TMPL" "$OVERRIDE_FILE" "$DCMI_SCRIPT" "$ENV_FILE"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
[ -n "${INFLUX_TOKEN:-}" ] || { echo "FATAL: INFLUX_TOKEN not set in $ENV_FILE" >&2; exit 1; }

# Build DCMI block (empty for --no-dcmi)
DCMI_BLOCK=""
if [ "$DCMI" = "1" ]; then
    DCMI_BLOCK='[[inputs.exec]]
  commands = ["/usr/local/bin/dcmi_collect.sh '"$HOST"'"]
  interval = "60s"
  timeout = "10s"
  data_format = "influx"'
fi

# Substitute placeholders locally
BASE_CONF=$(sed -e "s/__HOST__/$HOST/g" -e "s|__TOKEN__|$INFLUX_TOKEN|g" "$BASE_TMPL")
IPMI_CONF=$(awk -v host="$HOST" -v dcmi="$DCMI_BLOCK" '{
    gsub(/__HOST__/, host)
    if ($0 == "__DCMI_BLOCK__") { print dcmi; next }
    print
}' "$IPMI_TMPL")
OVERRIDE_CONF=$(cat "$OVERRIDE_FILE")
DCMI_SCRIPT_CONTENT=$(cat "$DCMI_SCRIPT")

# Base64-encode for safe transport through ssh (avoids any quoting hell with $ signs in scripts)
B64_BASE=$(printf '%s' "$BASE_CONF" | base64 -w0)
B64_IPMI=$(printf '%s' "$IPMI_CONF" | base64 -w0)
B64_OVERRIDE=$(printf '%s' "$OVERRIDE_CONF" | base64 -w0)
B64_DCMI=$(printf '%s' "$DCMI_SCRIPT_CONTENT" | base64 -w0)

echo "=== deploying telegraf to $HOST (dcmi=$DCMI) ==="

ssh "root@$HOST" "B64_BASE='$B64_BASE' B64_IPMI='$B64_IPMI' B64_OVERRIDE='$B64_OVERRIDE' B64_DCMI='$B64_DCMI' bash -s" <<'REMOTE'
set -euo pipefail

echo "=== InfluxData repo ==="
if [ ! -f /etc/apt/keyrings/influxdata-archive-keyring.gpg ] || ! grep -q influxdata /etc/apt/sources.list.d/influxdata.list 2>/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repos.influxdata.com/influxdata-archive.key | gpg --dearmor -o /etc/apt/keyrings/influxdata-archive-keyring.gpg
    chmod 644 /etc/apt/keyrings/influxdata-archive-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/influxdata-archive-keyring.gpg] https://repos.influxdata.com/debian stable main' > /etc/apt/sources.list.d/influxdata.list
    apt-get update -qq
else
    echo "  repo already configured, skipping"
fi

echo "=== installing telegraf ==="
if telegraf --version 2>/dev/null | grep -q '1\.32'; then
    echo "  telegraf 1.32 already installed, skipping"
else
    apt-get install -y telegraf=1.32.*
fi

echo "=== writing config files ==="
echo "$B64_BASE" | base64 -d > /etc/telegraf/telegraf.conf

mkdir -p /etc/telegraf/telegraf.d
echo "$B64_IPMI" | base64 -d > /etc/telegraf/telegraf.d/ipmi.conf

mkdir -p /etc/systemd/system/telegraf.service.d
echo "$B64_OVERRIDE" | base64 -d > /etc/systemd/system/telegraf.service.d/override.conf

echo "$B64_DCMI" | base64 -d > /usr/local/bin/dcmi_collect.sh
chmod 0755 /usr/local/bin/dcmi_collect.sh

echo "=== starting service ==="
systemctl daemon-reload
systemctl enable --now telegraf

echo "=== journal tail (5s wait) ==="
sleep 5
journalctl -u telegraf -n 30 --no-pager
REMOTE

echo "=== done deploying to $HOST ==="
