#!/data/data/com.termux/files/usr/bin/bash

NETWORK_STATUS="STARTING"
NETWORK_PING="--"
NETWORK_HOST="--"

NETWORK_ERRORS=0
NETWORK_TIMEOUTS=0
NETWORK_BAD_COUNT=0
NETWORK_RECOVERIES=0

NETWORK_LAST_GOOD=0

network_guard() {

    local hosts="1.1.1.1 8.8.8.8"
    local host=""
    local result=""
    local ping_ms=""
    local rc=0

    local timeout_sec="${NETWORK_TIMEOUT:-8}"

    local best_ping=""
    local best_host=""

    local previous_bad="$NETWORK_BAD_COUNT"

    NETWORK_STATUS="CHECKING"
    NETWORK_PING="--"
    NETWORK_HOST="--"

    if ! have_cmd ping; then
        NETWORK_STATUS="COMMAND_MISSING"
        NETWORK_ERRORS=$((NETWORK_ERRORS + 1))
        return 1
    fi

    for host in $hosts; do

        result="$(timeout "$timeout_sec" \
            ping -c 1 -W 3 "$host" 2>/dev/null)"

        rc=$?

        if [ "$rc" -eq 124 ]; then
            NETWORK_TIMEOUTS=$((NETWORK_TIMEOUTS + 1))
            continue
        fi

        if [ "$rc" -ne 0 ]; then
            continue
        fi

        ping_ms="$(printf '%s\n' "$result" |
            grep -oE 'time[=<][0-9.]+' |
            head -n 1 |
            sed 's/^time[=<]//')"

        if [ -z "$ping_ms" ]; then
            continue
        fi

        if ! awk -v p="$ping_ms" \
            'BEGIN { exit !(p ~ /^[0-9]+([.][0-9]+)?$/) }'
        then
            continue
        fi

        if [ -z "$best_ping" ]; then

            best_ping="$ping_ms"
            best_host="$host"

        elif awk -v n="$ping_ms" \
                 -v b="$best_ping" \
                 'BEGIN { exit !(n < b) }'
        then

            best_ping="$ping_ms"
            best_host="$host"

        fi

    done

    # ไม่มี host ไหนตอบ
    if [ -z "$best_ping" ]; then

        NETWORK_ERRORS=$((NETWORK_ERRORS + 1))
        NETWORK_BAD_COUNT=$((NETWORK_BAD_COUNT + 1))

        if [ -s "$STATE_DIR/network.state" ]; then
            NETWORK_STATUS="OFFLINE_CACHE"
        else
            NETWORK_STATUS="OFFLINE"
        fi

        return 1
    fi

    NETWORK_PING="$best_ping"
    NETWORK_HOST="$best_host"

    if declare -F network_history_update >/dev/null 2>&1; then
        network_history_update
    fi

    # แบ่งระดับ Ping
    if awk -v p="$NETWORK_PING" \
        -v g="${PING_GOOD:-50}" \
        'BEGIN { exit !(p <= g) }'
    then

        NETWORK_STATUS="GOOD"

    elif awk -v p="$NETWORK_PING" \
        -v w="${PING_WARNING:-120}" \
        'BEGIN { exit !(p <= w) }'
    then

        NETWORK_STATUS="WARNING"

    else

        NETWORK_STATUS="BAD"

    fi

    # Recovery: ก่อนหน้านี้ BAD แล้วกลับมา GOOD/WARNING
    if [ "$NETWORK_STATUS" != "BAD" ]; then

        if [ "$previous_bad" -gt 0 ]; then
            NETWORK_RECOVERIES=$((NETWORK_RECOVERIES + 1))
        fi

        NETWORK_BAD_COUNT=0

        NETWORK_LAST_GOOD="$(date +%s)"

    else

        NETWORK_BAD_COUNT=$((NETWORK_BAD_COUNT + 1))

    fi

    printf \
'STATUS=%s
PING=%s
HOST=%s
TIME=%s
BAD_COUNT=%s
ERRORS=%s
TIMEOUTS=%s
RECOVERIES=%s
LAST_GOOD=%s
' \
        "$NETWORK_STATUS" \
        "$NETWORK_PING" \
        "$NETWORK_HOST" \
        "$(date +%s)" \
        "$NETWORK_BAD_COUNT" \
        "$NETWORK_ERRORS" \
        "$NETWORK_TIMEOUTS" \
        "$NETWORK_RECOVERIES" \
        "$NETWORK_LAST_GOOD" \
        > "$STATE_DIR/network.state"

    return 0
}
