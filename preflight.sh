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

rm -f \
"$BATTERY_JSON" \
"$BATTERY_ERR" \
"$GPS_JSON" \
"$GPS_ERR"

echo "=================================================="
echo " LIVE MAN API GUARD - RUNTIME PREFLIGHT v2"
echo "=================================================="

echo
echo "===== COMMANDS ====="

MISSING=0

for CMD in \
bash \
jq \
timeout \
awk \
grep \
ping \
termux-battery-status \
termux-location \
date
do
    if command -v "$CMD" >/dev/null 2>&1; then
        echo "PASS: $CMD -> $(command -v "$CMD")"
    else
        echo "MISSING: $CMD"
        MISSING=$((MISSING + 1))
    fi
done

echo
echo "===== TERMUX:API BATTERY ====="

if timeout 8 termux-battery-status \
>"$BATTERY_JSON" \
2>"$BATTERY_ERR"
then

    echo "BATTERY API: COMMAND PASS"

    if jq -e '
        type == "object"
        and (.percentage != null)
        and (.temperature != null)
    ' "$BATTERY_JSON" >/dev/null 2>&1
    then

        echo "BATTERY JSON: PASS"

        jq '{
            percentage,
            temperature,
            status,
            plugged
        }' "$BATTERY_JSON"

    else

        echo "BATTERY JSON: INVALID"
        cat "$BATTERY_JSON"

    fi

else

    RC=$?

    echo "BATTERY API: FAILED rc=$RC"

    if [ -s "$BATTERY_ERR" ]; then
        echo "ERROR:"
        cat "$BATTERY_ERR"
    fi

fi


echo
echo "===== TERMUX:API GPS ====="

if command -v termux-location >/dev/null 2>&1
then

    if timeout 10 termux-location -p gps \
    >"$GPS_JSON" \
    2>"$GPS_ERR"
    then

        echo "GPS API: COMMAND PASS"

        if jq -e '
            type == "object"
            and (.latitude != null)
            and (.longitude != null)
        ' "$GPS_JSON" >/dev/null 2>&1
        then

            echo "GPS JSON: PASS"

            jq '{
                latitude,
                longitude,
                accuracy,
                speed,
                bearing
            }' "$GPS_JSON"

        else

            echo "GPS JSON: INVALID"
            cat "$GPS_JSON"

        fi

    else

        RC=$?

        echo "GPS API: FAILED rc=$RC"

        if [ -s "$GPS_ERR" ]; then
            echo "ERROR:"
            cat "$GPS_ERR"
        fi

    fi

else

    echo "GPS API: NOT INSTALLED"

fi


echo
echo "===== NETWORK ====="

if timeout 8 ping -c 1 1.1.1.1 >/dev/null 2>&1
then
    echo "NETWORK: PASS"
else
    echo "NETWORK: FAILED"
fi


echo
echo "===== PREFLIGHT RESULT ====="

if [ "$MISSING" -eq 0 ]; then
    echo "DEPENDENCIES: PASS"
else
    echo "DEPENDENCIES: WARNING ($MISSING missing)"
fi

echo
echo "Temp directory: $TMP"

echo "=================================================="
echo " PREFLIGHT COMPLETE"
echo "=================================================="
