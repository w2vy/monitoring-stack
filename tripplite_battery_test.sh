#!/bin/bash
# tripplite_battery_test.sh — manual front-panel-TEST capture for Tripp Lite UPSes
#
# Tripp Lite HID driver (09ae:3016) has no test.battery.start.* instcmd, so
# battery_weekly_test.sh skips these UPSes. But the front-panel TEST button is
# observable via NUT: ups.status transitions OL → OL DISCHRG → OL CHRG over ~10s,
# and battery.voltage sags under load — that sag is the replace signal.
#
# Workflow: user invokes this from a terminal, walks to the UPS room, presses
# the TEST button, walks back. The script captures the sag and logs it to
# InfluxDB (measurement: ups_test, manual=1).
#
# Source-of-truth: ~/Claude/monitoring-stack/
# Deployed to:     w2vy:/home/tom/monitoring-stack/
# Typical use:     ssh w2vy '~/monitoring-stack/tripplite_battery_test.sh tripplite'

set -uo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [<ups_name>] [--window <seconds>] [--set-baseline] [--note "text"] [--dry-run]
       $(basename "$0") --help

  <ups_name>       NUT UPS name (default: tripplite). Mapping to host:ip is hardcoded below.
  --window N       Max seconds to wait for OL DISCHRG (default: 300).
  --set-baseline   On successful capture, overwrite the baseline for this UPS in
                   ups_battery_baselines.json (use after a battery replacement).
  --note "text"    Free-text note attached to the baseline entry.
  --dry-run        Poll and print results, but don't write to InfluxDB or baselines file.
  --help           Show this help.

Exit codes:
  0  test captured successfully
  2  timeout (no DISCHRG observed within window)
  3  UPS already on battery (real outage in progress — don't test)
  4  upsc unreachable / UPS not found
  5  argument error
EOF
}

# ---------- arg parsing ----------
UPS_NAME=""
WINDOW=300
SET_BASELINE=0
NOTE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --window) WINDOW="$2"; shift 2 ;;
        --set-baseline) SET_BASELINE=1; shift ;;
        --note) NOTE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --*) echo "Unknown flag: $1" >&2; usage >&2; exit 5 ;;
        *) UPS_NAME="$1"; shift ;;
    esac
done

UPS_NAME="${UPS_NAME:-tripplite}"

# host:ip per NUT master (matches battery_weekly_test.sh UPSES list)
case "$UPS_NAME" in
    tripplite) UPS_HOST="pve55"; UPS_IP="192.168.102.55" ;;
    *) echo "Unknown UPS name: $UPS_NAME (extend the case statement)" >&2; exit 5 ;;
esac

UPS_REMOTE="${UPS_NAME}@${UPS_IP}"

# ---------- env / config ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
fi

INFLUX_URL="${INFLUX_URL:-http://localhost:8086}"
INFLUX_ORG="${INFLUX_ORG:-moltentech}"
INFLUX_BUCKET="${INFLUX_BUCKET:-monitoring}"
BASELINES_FILE="${BASELINES_FILE:-$SCRIPT_DIR/ups_battery_baselines.json}"

if [ "$DRY_RUN" -eq 0 ]; then
    : "${INFLUX_TOKEN:?INFLUX_TOKEN not set (export it or put it in $ENV_FILE)}"
fi

# ---------- pre-flight ----------
pre=$(upsc "$UPS_REMOTE" 2>/dev/null) || {
    echo "ERROR: upsc unreachable: $UPS_REMOTE" >&2
    exit 4
}

initial_status=$(echo "$pre" | awk -F': ' '/^ups\.status:/{print $2}')
initial_charge=$(echo "$pre" | awk -F': ' '/^battery\.charge:/{print $2}')
model=$(echo "$pre" | awk -F': ' '/^ups\.model:/{print $2}' | sed 's/[[:space:]]*$//;s/ /_/g')

if [[ "$initial_status" == *"OB"* ]]; then
    echo "ERROR: UPS is already on battery (status=$initial_status). Don't test during a real outage." >&2
    if [ "$DRY_RUN" -eq 0 ]; then
        line="ups_test,host=${UPS_HOST},ups_model=${model:-unknown},ups_name=${UPS_NAME} "
        line+="passed=0i,manual=1i,result=\"already_on_battery\""
        curl -s -X POST "${INFLUX_URL}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s" \
            -H "Authorization: Token ${INFLUX_TOKEN}" --data-binary "$line" >/dev/null
    fi
    exit 3
fi

echo "UPS:    $UPS_REMOTE  (model: ${model:-unknown})"
echo "Status: $initial_status  (charge: ${initial_charge}%)"
echo
echo ">>> Press the TEST button on the front of the UPS within ${WINDOW}s <<<"
echo

# ---------- capture loop ----------
state="WAIT"
v_pre=""
last_ol_voltage=""
v_min=""
load_pct=""
ts_start=""
ts_end=""
start_epoch=$(date +%s)

while :; do
    elapsed=$(( $(date +%s) - start_epoch ))
    if [ "$elapsed" -ge "$WINDOW" ] && [ "$state" = "WAIT" ]; then
        break
    fi

    snap=$(upsc "$UPS_REMOTE" 2>/dev/null) || true
    [ -z "$snap" ] && { sleep 2; continue; }

    status=$(echo "$snap" | awk -F': ' '/^ups\.status:/{print $2}')
    voltage=$(echo "$snap" | awk -F': ' '/^battery\.voltage:/{print $2}')
    load=$(echo "$snap" | awk -F': ' '/^ups\.load:/{print $2}')

    case "$state" in
        WAIT)
            if [[ "$status" == *"DISCHRG"* ]]; then
                state="IN_TEST"
                ts_start=$(date +%s)
                v_pre="${last_ol_voltage:-$voltage}"
                v_min="$voltage"
                load_pct="$load"
                echo "[$(date +%H:%M:%S)] DISCHRG detected (v_pre=$v_pre, load=$load%) — capturing..."
            elif [[ "$status" == *"OL"* ]]; then
                last_ol_voltage="$voltage"
            fi
            ;;
        IN_TEST)
            # Track minimum voltage and the load% at that moment.
            if [ -n "$voltage" ] && awk -v a="$voltage" -v b="$v_min" 'BEGIN{exit !(a<b)}'; then
                v_min="$voltage"
                load_pct="$load"
            fi
            if [[ "$status" != *"DISCHRG"* ]]; then
                ts_end=$(date +%s)
                state="DONE"
                echo "[$(date +%H:%M:%S)] DISCHRG ended (status=$status, v_min=$v_min)"
                break
            fi
            ;;
    esac

    sleep 2
done

# ---------- results ----------
if [ "$state" != "DONE" ]; then
    echo
    echo "TIMEOUT: no DISCHRG observed in ${WINDOW}s — was the button pressed?" >&2
    if [ "$DRY_RUN" -eq 0 ]; then
        line="ups_test,host=${UPS_HOST},ups_model=${model:-unknown},ups_name=${UPS_NAME} "
        line+="passed=0i,manual=1i,result=\"timeout\""
        curl -s -X POST "${INFLUX_URL}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s" \
            -H "Authorization: Token ${INFLUX_TOKEN}" --data-binary "$line" >/dev/null
    fi
    exit 2
fi

duration_s=$(( ts_end - ts_start ))
v_delta=$(awk -v a="$v_pre" -v b="$v_min" 'BEGIN{printf "%.2f", a-b}')

echo
echo "===== Test captured ====="
echo "  v_pre:     ${v_pre} V"
echo "  v_min:     ${v_min} V"
echo "  v_delta:   ${v_delta} V  (sag under ${load_pct}% load)"
echo "  duration:  ${duration_s}s"

# ---------- baseline comparison ----------
if [ -f "$BASELINES_FILE" ] && command -v jq >/dev/null 2>&1; then
    bl_delta=$(jq -r --arg u "$UPS_NAME" '.[$u].v_delta // empty' "$BASELINES_FILE" 2>/dev/null)
    bl_min=$(jq -r --arg u "$UPS_NAME" '.[$u].v_min // empty' "$BASELINES_FILE" 2>/dev/null)
    if [ -n "$bl_delta" ] && [ -n "$bl_min" ]; then
        verdict=$(awk -v cur="$v_delta" -v cmin="$v_min" -v bd="$bl_delta" -v bm="$bl_min" 'BEGIN{
            if (cur > bd * 1.5)     {print "WARN"; exit}
            if (cmin < bm - 1.5)    {print "WARN"; exit}
            print "OK"
        }')
        case "$verdict" in
            OK)   echo "  baseline: v_delta=${bl_delta}V, v_min=${bl_min}V — within tolerance ✅" ;;
            WARN) echo "  baseline: v_delta=${bl_delta}V, v_min=${bl_min}V — DRIFT detected ⚠️  (consider replacement)" ;;
        esac
    fi
fi

# ---------- InfluxDB write ----------
if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "[dry-run] would write to InfluxDB: ups_test host=$UPS_HOST ups_model=$model ups_name=$UPS_NAME"
else
    line="ups_test,host=${UPS_HOST},ups_model=${model:-unknown},ups_name=${UPS_NAME} "
    line+="passed=1i,manual=1i,v_pre=${v_pre},v_min=${v_min},v_delta=${v_delta},load_pct=${load_pct},duration_s=${duration_s}i,result=\"captured\""
    curl -sS -X POST "${INFLUX_URL}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s" \
        -H "Authorization: Token ${INFLUX_TOKEN}" --data-binary "$line" >/dev/null
    echo "wrote ups_test row to InfluxDB"
fi

# ---------- baseline update ----------
if [ "$SET_BASELINE" -eq 1 ]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: --set-baseline requires jq" >&2
        exit 5
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] would update baseline for $UPS_NAME in $BASELINES_FILE"
    else
        [ -f "$BASELINES_FILE" ] || echo '{"description":"Per-UPS battery baselines from front-panel TEST press. Updated on battery replacement. Older rows kept as audit trail in InfluxDB ups_test series."}' > "$BASELINES_FILE"
        today=$(date +%Y-%m-%d)
        tmp=$(mktemp)
        jq --arg u "$UPS_NAME" \
           --arg model "${model:-unknown}" \
           --arg date "$today" \
           --arg note "$NOTE" \
           --argjson v_pre "$v_pre" \
           --argjson v_min "$v_min" \
           --argjson v_delta "$v_delta" \
           --argjson load "$load_pct" \
           '.[$u] = {ups_model: $model, baseline_date: $date, v_pre: $v_pre, v_min: $v_min, v_delta: $v_delta, load_pct: $load, note: (if $note == "" then null else $note end)}' \
           "$BASELINES_FILE" > "$tmp" && mv "$tmp" "$BASELINES_FILE"
        echo "updated baseline for $UPS_NAME in $BASELINES_FILE"
    fi
fi
