#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$HOME/LIVE_MAN_API_GUARD"
TMP="$ROOT/tmp"

mkdir -p "$TMP"
chmod 700 "$TMP" 2>/dev/null || true

BATTERY_JSON="$TMP/liveman_battery_test.json"
BATTERY_ERR="$TMP/liveman_battery_error.log"
GPS_JSON="$TMP/liveman_gps_test.json"
GPS_ERR="$TMP/liveman_gps_error.log"

rm -f "$BATTERY_JSON" "$BATTERY_ERR" "$GPS_JSON" "$GPS_ERR"

FAIL=0
BATTERY_OK=0
GPS_OK=0
NETWORK_OK=0

echo "=================================================="
echo " LIVE MAN API GUARD - RUNTIME PREFLIGHT v3"
echo "=================================================="

echo
echo "===== COMMANDS ====="

for CMD in bash jq timeout awk grep ping termux-battery-status termux-location date
do
    if command -v "$CMD" >/dev/null 2>&1; then
        echo "PASS: $CMD -> $(command -v "$CMD")"
    else
        echo "FAIL: $CMD missing"
        FAIL=1
    fi
done

echo
echo "===== TERMUX:API BATTERY ====="

if command -v termux-battery-status >/dev/null 2>&1 &&
   timeout 8 termux-battery-status >"$BATTERY_JSON" 2>"$BATTERY_ERR"
then
    if jq -e '
        type == "object"
        and (.percentage != null)
        and (.temperature != null)
    ' "$BATTERY_JSON" >/dev/null 2>&1
    then
        BATTERY_OK=1
        echo "BATTERY API: PASS"
        jq '{percentage,temperature,status,plugged}' "$BATTERY_JSON"
    else
        echo "BATTERY API: FAIL - INVALID JSON"
        cat "$BATTERY_JSON" 2>/dev/null || true
        FAIL=1
    fi
else
    RC=$?
    echo "BATTERY API: FAIL rc=$RC"
    cat "$BATTERY_ERR" 2>/dev/null || true
    FAIL=1
fi

echo
echo "===== TERMUX:API GPS ====="

if command -v termux-location >/dev/null 2>&1 &&
   timeout 15 termux-location -p gps >"$GPS_JSON" 2>"$GPS_ERR"
then
    if jq -e '
        type == "object"
        and (.latitude != null)
        and (.longitude != null)
        and (.accuracy != null)
    ' "$GPS_JSON" >/dev/null 2>&1
    then
        GPS_OK=1
        echo "GPS API: PASS"
        jq '{latitude,longitude,accuracy,speed,bearing}' "$GPS_JSON"
    else
        echo "GPS API: FAIL - INVALID JSON"
        cat "$GPS_JSON" 2>/dev/null || true
        FAIL=1
    fi
else
    RC=$?
    echo "GPS API: FAIL rc=$RC"
    cat "$GPS_ERR" 2>/dev/null || true
    FAIL=1
fi

echo
echo "===== NETWORK ====="

if timeout 8 ping -c 3 -W 3 1.1.1.1 >/dev/null 2>&1
then
    NETWORK_OK=1
    echo "NETWORK: PASS"
else
    echo "NETWORK: FAIL"
    FAIL=1
fi

echo
echo "===== PREFLIGHT RESULT ====="

if [ "$FAIL" -eq 0 ] &&
   [ "$BATTERY_OK" -eq 1 ] &&
   [ "$GPS_OK" -eq 1 ] &&
   [ "$NETWORK_OK" -eq 1 ]
then
    echo "DEPENDENCIES : PASS"
    echo "BATTERY      : PASS"
    echo "GPS          : PASS"
    echo "NETWORK      : PASS"
    echo "RESULT       : PASS"
    RESULT=0
else
    echo "DEPENDENCIES : $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"
    echo "BATTERY      : $([ "$BATTERY_OK" -eq 1 ] && echo PASS || echo FAIL)"
    echo "GPS          : $([ "$GPS_OK" -eq 1 ] && echo PASS || echo FAIL)"
    echo "NETWORK      : $([ "$NETWORK_OK" -eq 1 ] && echo PASS || echo FAIL)"
    echo "RESULT       : FAIL"
    RESULT=1
fi

echo
echo "Temp directory: $TMP"
echo "=================================================="
echo " PREFLIGHT COMPLETE"
echo "=================================================="

exit "$RESULT"
