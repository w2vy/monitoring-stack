#!/bin/bash
# battery_weekly_test.sh — APC UPS quick self-test runner for the fleet
#
# Loops through all NUT masters, runs `test.battery.start.quick` on each,
# captures the result, writes to InfluxDB (measurement: ups_test),
# and emails on failure.
#
# Source-of-truth: ~/Claude/monitoring-stack/
# Deployed to: w2vy:/home/tom/monitoring-stack/
#
# Cron (weekly, Sundays 03:00 local):
#   0 3 * * 0 /home/tom/monitoring-stack/battery_weekly_test.sh >> /var/log/ups_weekly_test.log 2>&1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
fi

: "${INFLUX_TOKEN:?INFLUX_TOKEN not set (export it or put it in $ENV_FILE)}"
: "${NUT_PASSWORD:?NUT_PASSWORD not set (export it or put it in $ENV_FILE)}"

NUT_USER="${NUT_USER:-monitor}"
NUT_PASS="$NUT_PASSWORD"

INFLUX_URL="${INFLUX_URL:-http://localhost:8086}"
INFLUX_ORG="${INFLUX_ORG:-moltentech}"
INFLUX_BUCKET="${INFLUX_BUCKET:-monitoring}"

EMAIL_TO="tom@moltentech.us"
EMAIL_FROM="tom@moltentech.us"

# host:ip:ups_name triples — must match keys used by nut_collect.sh / telegraf.conf
# UPS_name needed because not all masters use "apc" (pve55 uses "tripplite").
# Drivers that don't expose test.battery.start.quick (e.g. Tripp Lite HID) are
# auto-skipped at runtime via the upscmd -l probe below.
UPSES=(
  "mtm0:192.168.2.50:apc"
  "mtm2:192.168.2.52:apc"
  "mtm3:192.168.2.53:apc"
  "mtm4:192.168.2.54:apc"
  "mtm5:192.168.2.55:apc"
  "pve20:192.168.102.20:apc"
  "pve55:192.168.102.55:tripplite"
)

# wait after triggering before reading result; we observed 25-50s in our tests
TEST_WAIT_SECONDS=75
# spacing between tests
SPACING_SECONDS=15
# skip threshold for battery.charge percentage (don't test a discharged battery)
MIN_CHARGE_PCT=90

failures=()
log_lines=()

run_now=$(date '+%Y-%m-%d %H:%M:%S %Z')
echo "==== Weekly UPS battery test ${run_now} ===="

for entry in "${UPSES[@]}"; do
    # parse host:ip:ups_name
    IFS=':' read -r host ip ups_name <<< "$entry"
    ups_name="${ups_name:-apc}"

    # snapshot pre-state
    pre=$(upsc "${ups_name}@${ip}" 2>/dev/null) || {
        msg="[$host] ERROR - upsc unreachable"
        echo "$msg"
        log_lines+=("$msg")
        failures+=("$host: upsc unreachable")
        continue
    }

    status=$(echo "$pre" | awk -F': ' '/^ups\.status:/{print $2}')
    charge=$(echo "$pre" | awk -F': ' '/^battery\.charge:/{print $2}')
    v_pre=$(echo "$pre" | awk -F': ' '/^battery\.voltage:/{print $2}')
    model=$(echo "$pre" | awk -F': ' '/^ups\.model:/{print $2}' | sed 's/[[:space:]]*$//;s/ /_/g')

    # capability check: skip if driver doesn't expose test.battery.start.quick
    # (Tripp Lite HID for product 09ae:3016 omits all test instcmds — quiet skip, not a failure)
    if ! upscmd -l "${ups_name}@${ip}" 2>/dev/null | grep -q '^test\.battery\.start\.quick'; then
        msg="[$host] SKIP - driver has no test.battery.start.quick instcmd"
        echo "$msg"
        log_lines+=("$msg")
        continue
    fi

    # safety: don't test if already on battery
    if [[ "$status" == *"OB"* ]]; then
        msg="[$host] SKIP - currently on battery (status=$status)"
        echo "$msg"
        log_lines+=("$msg")
        continue
    fi

    # safety: don't test if charge is low
    if [[ -z "$charge" ]] || (( charge < MIN_CHARGE_PCT )); then
        msg="[$host] SKIP - low charge (${charge:-?}%)"
        echo "$msg"
        log_lines+=("$msg")
        continue
    fi

    # trigger
    if ! upscmd -u "$NUT_USER" -p "$NUT_PASS" "${ups_name}@${ip}" test.battery.start.quick >/dev/null 2>&1; then
        msg="[$host] FAIL - upscmd trigger denied (check upsd.users instcmds grant)"
        echo "$msg"
        log_lines+=("$msg")
        failures+=("$host: upscmd trigger denied")
        continue
    fi

    # verify the firmware actually started the test (APC BX has a cooldown
    # after a recent test — upscmd returns OK but firmware silently refuses).
    # During an active quick-test, ups.status contains "OFF" or "TEST".
    sleep 4
    mid_status=$(upsc "${ups_name}@${ip}" ups.status 2>/dev/null)
    if [[ "$mid_status" != *"OFF"* && "$mid_status" != *"TEST"* ]]; then
        msg="[$host] SKIP - trigger refused by firmware (status=$mid_status, likely cooldown from recent test)"
        echo "$msg"
        log_lines+=("$msg")
        # write a refused marker to InfluxDB (passed=0, refused=1) so the
        # signal is preserved without polluting pass/fail trend lines
        refused_line="ups_test,host=${host},ups_model=${model:-unknown} passed=0i,refused=1i"
        [[ -n "$v_pre" ]] && refused_line+=",v_pre=${v_pre}"
        refused_line+=",result=\"trigger_refused\""
        curl -s -X POST "${INFLUX_URL}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s" \
            -H "Authorization: Token ${INFLUX_TOKEN}" \
            --data-binary "$refused_line" > /dev/null
        sleep "$SPACING_SECONDS"
        continue
    fi

    # remaining wait (we already slept 4s of TEST_WAIT_SECONDS)
    sleep $(( TEST_WAIT_SECONDS - 4 ))

    post=$(upsc "${ups_name}@${ip}" 2>/dev/null)
    result=$(echo "$post" | awk -F': ' '/^ups\.test\.result:/{print $2}')
    v_post=$(echo "$post" | awk -F': ' '/^battery\.voltage:/{print $2}')
    runtime=$(echo "$post" | awk -F': ' '/^battery\.runtime:/{print $2}')

    passed=0
    if [[ "$result" == "Done and passed" ]]; then
        passed=1
    else
        failures+=("$host: ${result:-<no result>}")
    fi

    msg="[$host] result=\"$result\" v_pre=${v_pre} v_post=${v_post} runtime=${runtime}s"
    echo "$msg"
    log_lines+=("$msg")

    # write to InfluxDB (measurement: ups_test)
    # tags: host, model ; fields: passed, refused, v_pre, v_post, runtime, result
    line="ups_test,host=${host},ups_model=${model:-unknown} "
    line+="passed=${passed}i,refused=0i"
    [[ -n "$v_pre" ]]    && line+=",v_pre=${v_pre}"
    [[ -n "$v_post" ]]   && line+=",v_post=${v_post}"
    [[ -n "$runtime" ]]  && line+=",runtime=${runtime}i"
    line+=",result=\"${result:-unknown}\""

    curl -s -X POST "${INFLUX_URL}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s" \
        -H "Authorization: Token ${INFLUX_TOKEN}" \
        --data-binary "$line" > /dev/null

    sleep "$SPACING_SECONDS"
done

echo "==== Summary: ${#failures[@]} failure(s) ===="

# email only on failure (success runs stay quiet)
if [[ ${#failures[@]} -gt 0 ]]; then
    {
        echo "From: NUT Battery Test <${EMAIL_FROM}>"
        echo "To: ${EMAIL_TO}"
        echo "Subject: [UPS ALERT] Weekly battery test - ${#failures[@]} failure(s)"
        echo ""
        echo "Run: ${run_now}"
        echo ""
        echo "Failures:"
        printf '  - %s\n' "${failures[@]}"
        echo ""
        echo "Full run log:"
        printf '  %s\n' "${log_lines[@]}"
    } | /usr/sbin/sendmail -F "NUT Battery Test" -f "${EMAIL_FROM}" -t
fi
