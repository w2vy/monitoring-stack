#!/bin/bash
# Idempotent per-host telegraf SMART installer for Phase 2 drive-health monitoring.
# Usage:
#   deploy_host_smart.sh <hostname>                          # auto-scan SATA/NVMe
#   deploy_host_smart.sh <hostname> --megaraid N[,N,...]     # explicit megaraid slots
#   deploy_host_smart.sh <hostname> --scan-megaraid          # derive from smartctl --scan
#
# Prereq: target host already has telegraf 1.32 running (deployed via deploy_host_ipmi.sh).
# This script adds /etc/telegraf/telegraf.d/smart.conf and restarts telegraf.

set -euo pipefail

HOST="${1:?usage: $0 <hostname> [--megaraid N,N,...|--scan-megaraid]}"
MODE="${2:-direct}"
SLOTS="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMART_TMPL="$SCRIPT_DIR/telegraf-host-smart.conf.tmpl"

[ -f "$SMART_TMPL" ] || { echo "FATAL: missing $SMART_TMPL" >&2; exit 1; }

# Build the devices array string
build_devices_megaraid() {
    local slots_csv="$1"
    local out=""
    IFS=',' read -ra SLOT_ARR <<< "$slots_csv"
    for s in "${SLOT_ARR[@]}"; do
        [ -z "$out" ] || out="$out, "
        out="${out}\"/dev/sda -d megaraid,${s}\""
    done
    echo "$out"
}

DEVICES_STR=""
case "$MODE" in
    --megaraid)
        [ -n "$SLOTS" ] || { echo "FATAL: --megaraid requires N,N,... arg" >&2; exit 1; }
        DEVICES_STR=$(build_devices_megaraid "$SLOTS")
        echo "=== mode: explicit megaraid slots: $SLOTS ==="
        ;;
    --scan-megaraid)
        echo "=== mode: scan-megaraid (deriving device list from target) ==="
        SCAN=$(ssh "root@$HOST" "smartctl --scan | awk '/megaraid/ {print \$1\" \"\$2\" \"\$3}'")
        if [ -z "$SCAN" ]; then
            echo "FATAL: no megaraid devices found via smartctl --scan on $HOST" >&2
            exit 1
        fi
        # Build comma-separated quoted list
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            [ -z "$DEVICES_STR" ] || DEVICES_STR="$DEVICES_STR, "
            DEVICES_STR="${DEVICES_STR}\"${line}\""
        done <<< "$SCAN"
        echo "  found: $DEVICES_STR"
        ;;
    direct)
        echo "=== mode: direct (auto-scan SATA/NVMe via telegraf) ==="
        # Empty array tells telegraf to auto-scan
        ;;
    *)
        echo "FATAL: unknown mode '$MODE' (expected: --megaraid|--scan-megaraid|nothing)" >&2
        exit 1
        ;;
esac

# Substitute __DEVICES__ placeholder
SMART_CONF=$(awk -v devs="$DEVICES_STR" '{gsub(/__DEVICES__/, devs); print}' "$SMART_TMPL")

# Base64 transport (same pattern as deploy_host_ipmi.sh)
B64_SMART=$(printf '%s' "$SMART_CONF" | base64 -w0)

echo "=== deploying telegraf SMART config to $HOST ==="

ssh "root@$HOST" "B64_SMART='$B64_SMART' bash -s" <<'REMOTE'
set -euo pipefail

# Verify telegraf is already installed (must have been deployed via deploy_host_ipmi.sh first)
if ! systemctl is-active --quiet telegraf; then
    echo "FATAL: telegraf is not active on this host. Run deploy_host_ipmi.sh first." >&2
    exit 1
fi

NEEDED=()
command -v smartctl >/dev/null 2>&1 || NEEDED+=(smartmontools)
command -v nvme     >/dev/null 2>&1 || NEEDED+=(nvme-cli)
if [ ${#NEEDED[@]} -gt 0 ]; then
    echo "=== installing: ${NEEDED[*]} ==="
    apt-get install -y "${NEEDED[@]}"
fi

echo "=== writing /etc/telegraf/telegraf.d/smart.conf ==="
mkdir -p /etc/telegraf/telegraf.d
echo "$B64_SMART" | base64 -d > /etc/telegraf/telegraf.d/smart.conf

echo "=== restarting telegraf ==="
systemctl restart telegraf

echo "=== journal tail (5s wait) ==="
sleep 5
journalctl -u telegraf -n 20 --no-pager
REMOTE

echo "=== done deploying SMART to $HOST ==="
