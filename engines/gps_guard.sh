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

    local now timestamp

    now="$(date +%s)"
    timestamp="$(jq -r '.timestamp // empty' "$STATE_DIR/gps.state" 2>/dev/null || true)"

    case "$timestamp" in
        ''|*[!0-9]*)
            echo "999999"
            return
            ;;
    esac

    if [ "$timestamp" -gt "$now" ]; then
        echo "0"
    else
        echo $((now - timestamp))
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
    local requested_provider="${2:-unknown}"
    local new_acc
    local old_acc="--"
    local old_provider="--"
    local old_timestamp=""

    new_acc="$(printf '%s' "$output" | jq -r '.accuracy // "--"')"

    if [ -s "$STATE_DIR/gps.state" ]; then
        old_acc="$(jq -r '.accuracy // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
        old_provider="$(jq -r '.source_provider // .provider // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
        old_timestamp="$(jq -r '.timestamp // empty' "$STATE_DIR/gps.state" 2>/dev/null || true)"
    fi

    # V8.9.9:
    # The provider we requested is authoritative.
    # Do NOT trust .provider from Termux:API JSON because it may differ
    # from the requested provider.
    #
    # A worse NETWORK result must never overwrite a better GPS cache.
    old_age="$(gps_cache_age)"

    if [ "$requested_provider" = "network" ] &&
       [ "$old_provider" = "gps" ] &&
       [ "$new_acc" != "--" ] &&
       [ "$old_acc" != "--" ] &&
       [ "$old_age" -le "$max_age" ] &&
       awk -v old="$old_acc" -v new="$new_acc"            'BEGIN { exit !(old < new) }'
    then
        GPS_LAT="$(jq -r '.latitude // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
        GPS_LON="$(jq -r '.longitude // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
        GPS_ACC="$old_acc"
        GPS_SPEED="$(jq -r '.speed // "--"' "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
        GPS_PROVIDER="gps"
        GPS_CACHE_AGE="$(gps_cache_age)"

        gps_set_quality "$GPS_ACC"
        GPS_LAST_SOURCE="CACHE_PRESERVED"
        return 0
    fi

    GPS_LAT="$(printf '%s' "$output" | jq -r '.latitude // "--"')"
    GPS_LON="$(printf '%s' "$output" | jq -r '.longitude // "--"')"
    GPS_ACC="$new_acc"
    GPS_SPEED="$(printf '%s' "$output" | jq -r '.speed // "--"')"

    # Requested provider, not JSON provider.
    GPS_PROVIDER="$requested_provider"

    GPS_CACHE_AGE="0"
    gps_set_quality "$GPS_ACC"

    # Only store a fresh cache when the fix is reasonably useful.
    # GPS/Network fixes worse than 80m are not promoted to the main cache.
    if [ "$new_acc" != "--" ] &&
       awk -v a="$new_acc" 'BEGIN { exit !(a <= 80) }'
    then
        printf '%s\n' "$output" |
            jq --arg provider "$requested_provider" \
               --argjson ts "$(date +%s)" \
               '. + {timestamp:$ts, source_provider:$provider}' \
            > "$STATE_DIR/gps.state.tmp.$$" &&
            mv -f "$STATE_DIR/gps.state.tmp.$$" "$STATE_DIR/gps.state"
    fi

    GPS_LAST_SOURCE="$requested_provider"
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
            gps_apply_output "$GPS_LAST_OUTPUT" "network"

            # V8.9.8: a worse network result may be intentionally
            # rejected in favor of a better existing GPS cache.
            if [ "${GPS_LAST_SOURCE:-}" = "CACHE_PRESERVED" ]; then
                if [ "${GPS_CACHE_AGE:-999999}" -le "$max_age" ]; then
                    GPS_STATUS="GPS_CACHE_PRESERVED"
                    return 0
                fi
            fi

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
            gps_apply_output "$GPS_LAST_OUTPUT" "gps"

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
