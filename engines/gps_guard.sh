#!/data/data/com.termux/files/usr/bin/bash

GPS_STATUS="STARTING"
GPS_LAT="--"
GPS_LON="--"
GPS_ACC="--"
GPS_SPEED="--"
GPS_PROVIDER="--"
GPS_CACHE_AGE="--"
GPS_QUALITY="UNKNOWN"

GPS_API_ERRORS=0
GPS_TIMEOUTS=0
GPS_INVALID=0
GPS_RECOVERIES=0

GPS_COOLDOWN_UNTIL="${GPS_COOLDOWN_UNTIL:-0}"
GPS_LAST_PROBE="${GPS_LAST_PROBE:-0}"
GPS_PROBE_INTERVAL="${GPS_PROBE_INTERVAL:-30}"

# Network location is no longer called every rider round.
GPS_NETWORK_LAST_POLL="${GPS_NETWORK_LAST_POLL:-0}"
GPS_NETWORK_POLL_INTERVAL="${GPS_NETWORK_POLL_INTERVAL:-20}"
GPS_NETWORK_COOLDOWN_UNTIL="${GPS_NETWORK_COOLDOWN_UNTIL:-0}"
GPS_NETWORK_COOLDOWN="${GPS_NETWORK_COOLDOWN:-30}"

GPS_LAST_SOURCE="${GPS_LAST_SOURCE:-NONE}"
GPS_LAST_RC="${GPS_LAST_RC:-0}"
GPS_LAST_OUTPUT="${GPS_LAST_OUTPUT:-}"

gps_valid_json() {
    printf '%s' "$1" | jq -e '
        type == "object"
        and (.latitude != null)
        and (.longitude != null)
        and (.latitude | type == "number")
        and (.longitude | type == "number")
    ' >/dev/null 2>&1
}

gps_cache_age() {
    [ -s "$STATE_DIR/gps.state" ] || {
        echo "999999"
        return
    }

    local now mtime
    now="$(date +%s)"
    mtime="$(stat -c %Y "$STATE_DIR/gps.state" 2>/dev/null || echo 0)"

    case "$mtime" in
        ''|*[!0-9]*)
            echo "999999"
            return
            ;;
    esac

    if [ "$mtime" -gt "$now" ]; then
        echo "0"
    else
        echo $((now - mtime))
    fi
}

gps_set_quality() {
    local acc="${1:-}"

    if ! awk -v a="$acc" \
        'BEGIN { exit !(a ~ /^[0-9]+([.][0-9]+)?$/) }'
    then
        GPS_QUALITY="UNKNOWN"
        return
    fi

    if awk -v a="$acc" 'BEGIN { exit !(a <= 15) }'; then
        GPS_QUALITY="EXCELLENT"
    elif awk -v a="$acc" 'BEGIN { exit !(a <= 30) }'; then
        GPS_QUALITY="GOOD"
    elif awk -v a="$acc" 'BEGIN { exit !(a <= 50) }'; then
        GPS_QUALITY="FAIR"
    else
        GPS_QUALITY="POOR"
    fi
}

gps_apply_output() {
    local output="$1"

    GPS_LAT="$(printf '%s' "$output" | jq -r '.latitude // "--"')"
    GPS_LON="$(printf '%s' "$output" | jq -r '.longitude // "--"')"
    GPS_ACC="$(printf '%s' "$output" | jq -r '.accuracy // "--"')"
    GPS_SPEED="$(printf '%s' "$output" | jq -r '.speed // "--"')"
    GPS_PROVIDER="$(printf '%s' "$output" | jq -r '.provider // "unknown"')"

    GPS_CACHE_AGE="0"

    gps_set_quality "$GPS_ACC"

    printf '%s\n' "$output" > "$STATE_DIR/gps.state.tmp.$$" &&
        mv -f "$STATE_DIR/gps.state.tmp.$$" "$STATE_DIR/gps.state"

    GPS_LAST_SOURCE="$GPS_PROVIDER"
}

gps_try_provider() {
    local provider="$1"
    local output rc

    output="$(
        api_location \
            -p "$provider" \
            -r once \
            2>/dev/null
    )"

    rc=$?

    GPS_LAST_RC="$rc"
    GPS_LAST_OUTPUT="$output"

    if [ "$rc" -eq 0 ] &&
       [ -n "$output" ] &&
       gps_valid_json "$output"
    then
        return 0
    fi

    return 1
}

gps_load_cache() {
    [ -s "$STATE_DIR/gps.state" ] || return 1

    GPS_LAT="$(jq -r '.latitude // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
    GPS_LON="$(jq -r '.longitude // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
    GPS_ACC="$(jq -r '.accuracy // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
    GPS_SPEED="$(jq -r '.speed // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
    GPS_PROVIDER="$(jq -r '.provider // "cache"' "$STATE_DIR/gps.state" 2>/dev/null || echo "cache")"

    GPS_CACHE_AGE="$(gps_cache_age)"

    gps_set_quality "$GPS_ACC"

    return 0
}

gps_cooldown_active() {
    local now
    now="$(date +%s)"

    [ "${GPS_COOLDOWN_UNTIL:-0}" -gt "$now" ]
}

gps_set_cooldown() {
    local cooldown="${GPS_CIRCUIT_COOLDOWN:-30}"
    GPS_COOLDOWN_UNTIL=$(( $(date +%s) + cooldown ))
}

gps_probe_due() {
    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - ${GPS_LAST_PROBE:-0}))

    [ "$elapsed" -ge "${GPS_PROBE_INTERVAL:-30}" ]
}

gps_mark_probe() {
    GPS_LAST_PROBE="$(date +%s)"
}

gps_network_cooldown_active() {
    local now
    now="$(date +%s)"

    [ "${GPS_NETWORK_COOLDOWN_UNTIL:-0}" -gt "$now" ]
}

gps_set_network_cooldown() {
    local cooldown="${GPS_NETWORK_COOLDOWN:-30}"
    GPS_NETWORK_COOLDOWN_UNTIL=$(( $(date +%s) + cooldown ))
}

gps_network_poll_due() {
    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - ${GPS_NETWORK_LAST_POLL:-0}))

    [ "$elapsed" -ge "${GPS_NETWORK_POLL_INTERVAL:-20}" ]
}

gps_mark_network_poll() {
    GPS_NETWORK_LAST_POLL="$(date +%s)"
}

gps_guard() {
    local max_age="${GPS_CACHE_MAX_AGE:-300}"
    local network_max="${GPS_NETWORK_MAX_ACCURACY:-80}"

    GPS_STATUS="CHECKING"

    if ! declare -F api_location >/dev/null 2>&1; then
        GPS_STATUS="API_WRAPPER_MISSING"
        return 1
    fi

    if ! have_cmd jq; then
        GPS_STATUS="JQ_MISSING"
        return 1
    fi

    # ==================================================
    # 1) NETWORK LOCATION
    #    Poll only every N seconds.
    # ==================================================
    if gps_network_cooldown_active; then
        if gps_load_cache; then
            GPS_STATUS="LIVE_NETWORK_COOLDOWN"
            return 0
        fi
    elif gps_network_poll_due; then
        gps_mark_network_poll

        if gps_try_provider "network"; then
            gps_apply_output "$GPS_LAST_OUTPUT"

            # Good network location is immediately accepted.
            if awk -v a="$GPS_ACC" "BEGIN { exit !(a <= $network_max) }"; then
                GPS_STATUS="LIVE_NETWORK"
                return 0
            fi

            # Poor network fix: keep it, then allow GPS probe only
            # according to the normal GPS probe interval.
            GPS_STATUS="LIVE_NETWORK_PROBE_WAIT"
        else
            GPS_API_ERRORS=$((GPS_API_ERRORS + 1))

            # A timeout means Android/Termux:API needs a rest period.
            if [ "${GPS_LAST_RC:-0}" -eq 124 ]; then
                GPS_TIMEOUTS=$((GPS_TIMEOUTS + 1))
                gps_set_network_cooldown
            fi
        fi
    else
        # No API call this round.
        # Reuse the latest location without touching Termux:API.
        if gps_load_cache; then
            if [ "$GPS_CACHE_AGE" -le "$max_age" ]; then
                GPS_STATUS="LIVE_NETWORK_CACHE"
                return 0
            fi
        fi
    fi

    # ==================================================
    # 2) GPS PROVIDER
    #    Expensive provider is probed only periodically.
    #    Never probe immediately after a network timeout.
    # ==================================================
    if ! gps_network_cooldown_active &&
       ! gps_cooldown_active &&
       gps_probe_due
    then
        gps_mark_probe

        if gps_try_provider "gps"; then
            gps_apply_output "$GPS_LAST_OUTPUT"

            GPS_RECOVERIES=$((GPS_RECOVERIES + 1))
            GPS_STATUS="LIVE_GPS"
            return 0
        fi

        GPS_API_ERRORS=$((GPS_API_ERRORS + 1))

        if [ "${GPS_LAST_RC:-0}" -eq 124 ]; then
            GPS_TIMEOUTS=$((GPS_TIMEOUTS + 1))
            gps_set_cooldown
        else
            GPS_INVALID=$((GPS_INVALID + 1))
        fi

        # Keep valid cache if available.
        if gps_load_cache; then
            if [ "$GPS_CACHE_AGE" -le "$max_age" ]; then
                GPS_STATUS="CACHE_FRESH"
                return 0
            fi
        fi
    fi

    # ==================================================
    # 3) EXISTING NETWORK/CACHE RESULT
    # ==================================================
    if gps_load_cache; then
        if [ "$GPS_CACHE_AGE" -le "$max_age" ]; then
            GPS_STATUS="CACHE_FRESH"
            return 0
        fi

        GPS_STATUS="CACHE_STALE"
        return 1
    fi

    GPS_STATUS="NO_LOCATION"
    return 1
}
