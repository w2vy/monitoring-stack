#!/bin/bash
# Collects NUT UPS metrics and outputs in InfluxDB line protocol
# Usage: nut_collect.sh <host> <port> <ups_name> <host_tag>

HOST="$1"
PORT="${2:-3493}"
UPS_NAME="${3:-apc}"
HOST_TAG="${4:-$HOST}"

DATA=$(upsc "$UPS_NAME@$HOST:$PORT" 2>/dev/null)
if [ $? -ne 0 ]; then
    exit 0
fi

get_val() {
    echo "$DATA" | grep "^$1:" | cut -d' ' -f2
}

LOAD=$(get_val "ups.load")
REALPOWER=$(get_val "ups.realpower.nominal")
UPS_POWER=$(get_val "ups.power")
BATTERY_CHARGE=$(get_val "battery.charge")
BATTERY_RUNTIME=$(get_val "battery.runtime")
BATTERY_VOLTAGE=$(get_val "battery.voltage")
INPUT_VOLTAGE=$(get_val "input.voltage")
UPS_STATUS=$(get_val "ups.status")
UPS_MODEL=$(get_val "ups.model")

# InfluxDB line protocol: spaces in tag values must be escaped or replaced.
# Replace spaces with underscores so the full model name survives as a tag.
# Also trim trailing whitespace some drivers leave on model strings.
UPS_MODEL=$(echo "$UPS_MODEL" | sed 's/[[:space:]]*$//;s/ /_/g')
UPS_STATUS=$(echo "$UPS_STATUS" | sed 's/[[:space:]]*$//;s/ /_/g')

# Actual watts:
#   Tripp Lite HID driver reports ups.power directly (preferred).
#   APC BX series omits ups.power but exposes ups.load + ups.realpower.nominal,
#   so fall back to that computation.
if [ -n "$UPS_POWER" ]; then
    WATTS=$(printf "%.1f" "$UPS_POWER" 2>/dev/null)
elif [ -n "$LOAD" ] && [ -n "$REALPOWER" ]; then
    WATTS=$(echo "$LOAD * $REALPOWER / 100" | bc -l 2>/dev/null | xargs printf "%.1f" 2>/dev/null)
fi

# Output in InfluxDB line protocol
FIELDS=""
[ -n "$LOAD" ] && FIELDS="${FIELDS}load=${LOAD},"
[ -n "$WATTS" ] && FIELDS="${FIELDS}watts=${WATTS},"
[ -n "$REALPOWER" ] && FIELDS="${FIELDS}realpower_nominal=${REALPOWER},"
[ -n "$BATTERY_CHARGE" ] && FIELDS="${FIELDS}battery_charge=${BATTERY_CHARGE},"
[ -n "$BATTERY_RUNTIME" ] && FIELDS="${FIELDS}battery_runtime=${BATTERY_RUNTIME},"
[ -n "$BATTERY_VOLTAGE" ] && FIELDS="${FIELDS}battery_voltage=${BATTERY_VOLTAGE},"
[ -n "$INPUT_VOLTAGE" ] && FIELDS="${FIELDS}input_voltage=${INPUT_VOLTAGE},"

# Remove trailing comma
FIELDS="${FIELDS%,}"

if [ -n "$FIELDS" ]; then
    echo "ups,host=${HOST_TAG},ups_name=${UPS_NAME},ups_model=${UPS_MODEL:-unknown},ups_status=${UPS_STATUS:-unknown} ${FIELDS}"
fi
