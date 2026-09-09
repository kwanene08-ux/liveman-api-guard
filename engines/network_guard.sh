#!/data/data/com.termux/files/usr/bin/bash

NETWORK_STATUS="STARTING"
NETWORK_PING="--"
NETWORK_HOST="--"
NETWORK_PACKET_LOSS="--"
NETWORK_JITTER="--"
NETWORK_MIN="--"
NETWORK_MAX="--"

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
    local best_loss="--"
    local best_jitter="--"
    local best_min="--"
    local best_max="--"

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
        result="$(timeout "$timeout_sec" ping -c "${NETWORK_PING_COUNT:-5}" -W 3 "$host" 2>/dev/null)"
        rc=$?

        [ "$rc" -eq 124 ] && NETWORK_TIMEOUTS=$((NETWORK_TIMEOUTS + 1)) && continue
        [ "$rc" -ne 0 ] && continue

        ping_ms="$(printf '%s\n' "$result" | sed -n 's/.*rtt min\/avg\/max\/mdev = \([^/]*\)\/\([^/]*\)\/\([^/]*\)\/\([^ ]*\).*/\2/p')"
        min_ms="$(printf '%s\n' "$result" | sed -n 's/.*rtt min\/avg\/max\/mdev = \([^/]*\)\/\([^/]*\)\/\([^/]*\)\/\([^ ]*\).*/\1/p')"
        max_ms="$(printf '%s\n' "$result" | sed -n 's/.*rtt min\/avg\/max\/mdev = \([^/]*\)\/\([^/]*\)\/\([^ ]*\)\/\([^ ]*\).*/\3/p')"
        jitter_ms="$(printf '%s\n' "$result" | sed -n 's/.*rtt min\/avg\/max\/mdev = \([^/]*\)\/\([^/]*\)\/\([^/]*\)\/\([^ ]*\).*/\4/p')"
        loss_pct="$(printf '%s\n' "$result" | sed -n 's/.* received, \([0-9.]*\)% packet loss.*/\1/p')"

        [ -z "$ping_ms" ] && continue
        [ -z "$loss_pct" ] && loss_pct=100
        [ -z "$jitter_ms" ] && jitter_ms=0
        [ -z "$min_ms" ] && min_ms="$ping_ms"
        [ -z "$max_ms" ] && max_ms="$ping_ms"

        if [ -z "$best_ping" ] || awk -v n="$ping_ms" -v b="$best_ping" 'BEGIN { exit !(n < b) }'; then
            best_ping="$ping_ms"
            best_host="$host"
            best_loss="$loss_pct"
            best_jitter="$jitter_ms"
            best_min="$min_ms"
            best_max="$max_ms"
        fi
    done

    # ไม่มี host ไหนตอบ
    if [ -z "$best_ping" ]; then

        NETWORK_ERRORS=$((NETWORK_ERRORS + 1))
        NETWORK_BAD_COUNT=$((NETWORK_BAD_COUNT + 1))

        if [ -s "$STATE_DIR/network.state" ]; then
            # Transient loss with usable last-good state:
            # degraded state, not a structural engine failure.
            NETWORK_STATUS="OFFLINE_CACHE"
            return 0
        else
            NETWORK_STATUS="OFFLINE"
            return 1
        fi
    fi

    NETWORK_PING="$best_ping"
    NETWORK_HOST="$best_host"
    NETWORK_PACKET_LOSS="$best_loss"
    NETWORK_JITTER="$best_jitter"
    NETWORK_MIN="$best_min"
    NETWORK_MAX="$best_max"

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
LOSS=%s
JITTER=%s
MIN=%s
MAX=%s
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
        "$NETWORK_PACKET_LOSS" \
        "$NETWORK_JITTER" \
        "$NETWORK_MIN" \
        "$NETWORK_MAX" \
        "$(date +%s)" \
        "$NETWORK_BAD_COUNT" \
        "$NETWORK_ERRORS" \
        "$NETWORK_TIMEOUTS" \
        "$NETWORK_RECOVERIES" \
        "$NETWORK_LAST_GOOD" \
        > "$STATE_DIR/network.state"

    return 0
}
