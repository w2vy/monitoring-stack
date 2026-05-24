#!/bin/bash
# Collects IPMI DCMI power readings and emits InfluxDB line protocol.
# R7 contract (matches nut_collect.sh): exit 0 with empty stdout on any failure.
# Usage: dcmi_collect.sh <host_tag>

HOST_TAG="${1:-}"
[ -z "$HOST_TAG" ] && exit 0

IPMITOOL="${IPMITOOL:-/usr/bin/ipmitool}"

DATA=$("$IPMITOOL" -I open dcmi power reading 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$DATA" ]; then
    exit 0
fi

get_val() {
    echo "$DATA" | grep -F "$1" | awk -F: '{print $2}' | awk '{print $1}'
}

INSTANT=$(get_val "Instantaneous power reading")
MIN=$(get_val "Minimum during sampling period")
MAX=$(get_val "Maximum during sampling period")
AVG=$(get_val "Average power reading over sample period")

if [ -z "$INSTANT" ] || [ -z "$MIN" ] || [ -z "$MAX" ] || [ -z "$AVG" ]; then
    exit 0
fi

echo "ipmi_dcmi,host=${HOST_TAG} power_watts=${INSTANT},power_min=${MIN},power_max=${MAX},power_avg=${AVG}"
