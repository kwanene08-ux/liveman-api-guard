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
GPS_DRIFT_DETECTED=0

GPS_COOLDOWN_UNTIL="${GPS_COOLDOWN_UNTIL:-0}"
GPS_LAST_PROBE="${GPS_LAST_PROBE:-0}"
GPS_PROBE_INTERVAL="${GPS_PROBE_INTERVAL:-15}"

GPS_NETWORK_LAST_POLL="${GPS_NETWORK_LAST_POLL:-0}"
GPS_NETWORK_POLL_INTERVAL="${GPS_NETWORK_POLL_INTERVAL:-60}"
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

    timestamp="$(jq -r '.timestamp // empty' \
        "$STATE_DIR/gps.state" 2>/dev/null || true)"

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

gps_distance_meters() {
    local old_lat="$1"
    local old_lon="$2"
    local new_lat="$3"
    local new_lon="$4"

    awk -v la1="$old_lat" \
        -v lo1="$old_lon" \
        -v la2="$new_lat" \
        -v lo2="$new_lon" '
        BEGIN {
            pi=3.141592653589793
            mean=((la1+la2)/2)*pi/180
            dy=(la2-la1)*110540
            dx=(lo2-lo1)*111320*cos(mean)
            d=sqrt((dx*dx)+(dy*dy))
            printf "%.2f\n", d
        }'
}

gps_apply_output() {
    local output="$1"
    local requested_provider="${2:-unknown}"
    local new_acc
    local old_acc="--"
    local old_provider="--"
    local old_timestamp=""
    local old_lat="--"
    local old_lon="--"
    local old_age
    local max_age="${GPS_CACHE_MAX_AGE:-300}"
    local jump_meters="${GPS_JUMP_METERS:-100}"
    local jump_max_age="${GPS_JUMP_MAX_AGE:-120}"
    local jump_max_speed="${GPS_JUMP_MAX_SPEED_MPS:-8}"
    local distance="0"
    local inferred_speed="0"
    local reject_jump=0

    new_acc="$(printf '%s' "$output" |
        jq -r '.accuracy // "--"')"

    if [ -s "$STATE_DIR/gps.state" ]; then
        old_acc="$(jq -r '.accuracy // "--"' \
            "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"

        old_provider="$(jq -r \
            '.source_provider // .provider // "--"' \
            "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"

        old_timestamp="$(jq -r \
            '.timestamp // empty' \
            "$STATE_DIR/gps.state" 2>/dev/null || true)"

        old_lat="$(jq -r \
            '.latitude // "--"' \
            "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"

        old_lon="$(jq -r \
            '.longitude // "--"' \
            "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
    fi

    old_age="$(gps_cache_age)"

    # ==================================================
    # GPS DRIFT GUARD
    # GPS -> GPS only
    # Fresh GPS cache + impossible jump = reject
    # ==================================================
    if [ "$requested_provider" = "gps" ] &&
       [ "$old_provider" = "gps" ] &&
       [ "$old_age" -le "$jump_max_age" ] &&
       [ "$old_lat" != "--" ] &&
       [ "$old_lon" != "--" ]
    then
        if awk -v a="$(printf '%s' "$output" |
                jq -r '.latitude // empty')" \
            'BEGIN { exit !(a ~ /^-?[0-9]+([.][0-9]+)?$/) }' &&
           awk -v a="$(printf '%s' "$output" |
                jq -r '.longitude // empty')" \
            'BEGIN { exit !(a ~ /^-?[0-9]+([.][0-9]+)?$/) }'
        then
            local new_lat new_lon
            new_lat="$(printf '%s' "$output" |
                jq -r '.latitude')"
            new_lon="$(printf '%s' "$output" |
                jq -r '.longitude')"

            distance="$(gps_distance_meters \
                "$old_lat" "$old_lon" "$new_lat" "$new_lon")"

            if [ "$old_age" -gt 0 ]; then
                inferred_speed="$(awk \
                    -v d="$distance" \
                    -v t="$old_age" \
                    'BEGIN { printf "%.2f", d/t }')"
            fi

            if awk -v d="$distance" \
                -v jm="$jump_meters" \
                -v sp="$inferred_speed" \
                -v ms="$jump_max_speed" \
                'BEGIN { exit !(d > jm && sp <= ms) }'
            then
                reject_jump=1
            fi
        fi
    fi

    if [ "$reject_jump" -eq 1 ]; then
        GPS_LAT="$old_lat"
        GPS_LON="$old_lon"
        GPS_ACC="$old_acc"
        GPS_SPEED="$(jq -r '.speed // "--"' \
            "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
        GPS_PROVIDER="gps"
        GPS_CACHE_AGE="$old_age"

        gps_set_quality "$GPS_ACC"

        GPS_DRIFT_DETECTED=$((GPS_DRIFT_DETECTED + 1))
        GPS_LAST_SOURCE="DRIFT_REJECTED"
        GPS_STATUS="GPS_DRIFT_REJECTED"

        return 0
    fi

    # ==================================================
    # GPS authoritative rule
    # Never allow network to overwrite fresh GPS
    # ==================================================
    if [ "$requested_provider" = "network" ] &&
       [ "$old_provider" = "gps" ] &&
       [ "$old_age" -le "$max_age" ]
    then
        GPS_LAT="$old_lat"
        GPS_LON="$old_lon"
        GPS_ACC="$old_acc"
        GPS_SPEED="$(jq -r '.speed // "--"' \
            "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"
        GPS_PROVIDER="gps"
        GPS_CACHE_AGE="$old_age"

        gps_set_quality "$GPS_ACC"

        GPS_LAST_SOURCE="GPS_CACHE_PRESERVED"
        return 0
    fi

    GPS_LAT="$(printf '%s' "$output" |
        jq -r '.latitude // "--"')"

    GPS_LON="$(printf '%s' "$output" |
        jq -r '.longitude // "--"')"

    GPS_ACC="$new_acc"

    GPS_SPEED="$(printf '%s' "$output" |
        jq -r '.speed // "--"')"

    GPS_PROVIDER="$requested_provider"
    GPS_CACHE_AGE="0"

    gps_set_quality "$GPS_ACC"

    # Promote only useful fixes
    if [ "$new_acc" != "--" ] &&
       awk -v a="$new_acc" 'BEGIN { exit !(a <= 80) }'
    then
        printf '%s\n' "$output" |
            jq --arg provider "$requested_provider" \
               --argjson ts "$(date +%s)" \
               '. + {
                   timestamp:$ts,
                   source_provider:$provider
               }' \
            > "$STATE_DIR/gps.state.tmp.$$" &&

        mv -f "$STATE_DIR/gps.state.tmp.$$" \
            "$STATE_DIR/gps.state"
    fi

    GPS_LAST_SOURCE="$requested_provider"
}

gps_try_provider() {
    local provider="$1"
    local output rc
    local retries="${GPS_RETRIES:-1}"
    local attempt=0

    case "$retries" in
        ''|*[!0-9]*) retries=1 ;;
    esac

    while :; do
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

        # Retry only on timeout.
        # Do not repeat invalid/API errors because those should
        # immediately enter the existing fallback/cooldown logic.
        if [ "$provider" = "gps" ] &&
           [ "$rc" -eq 124 ] &&
           [ "$attempt" -lt "$retries" ]
        then
            attempt=$((attempt + 1))
            sleep 0.2
            continue
        fi

        return 1
    done
}

gps_load_cache() {
    [ -s "$STATE_DIR/gps.state" ] || return 1

    GPS_LAT="$(jq -r '.latitude // "--"' \
        "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"

    GPS_LON="$(jq -r '.longitude // "--"' \
        "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"

    GPS_ACC="$(jq -r '.accuracy // "--"' \
        "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"

    GPS_SPEED="$(jq -r '.speed // "--"' \
        "$STATE_DIR/gps.state" 2>/dev/null || echo "--")"

    GPS_PROVIDER="$(jq -r \
        '.source_provider // .provider // "cache"' \
        "$STATE_DIR/gps.state" 2>/dev/null || echo "cache")"

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

    [ "$elapsed" -ge "${GPS_PROBE_INTERVAL:-15}" ]
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

    [ "$elapsed" -ge "${GPS_NETWORK_POLL_INTERVAL:-60}" ]
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
    # 1. GPS FIRST
    # ==================================================
    if ! gps_cooldown_active &&
       gps_probe_due
    then
        gps_mark_probe

        if gps_try_provider "gps"; then
            gps_apply_output "$GPS_LAST_OUTPUT" "gps"

            if [ "${GPS_STATUS:-}" = "GPS_DRIFT_REJECTED" ]; then
                return 0
            fi

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
    fi

    # ==================================================
    # 2. Fresh GPS cache
    # ==================================================
    if gps_load_cache; then
        if [ "$GPS_PROVIDER" = "gps" ] &&
           [ "$GPS_CACHE_AGE" -le "$max_age" ]
        then
            GPS_STATUS="CACHE_FRESH"
            return 0
        fi
    fi

    # ==================================================
    # 3. Network fallback only
    # ==================================================
    if ! gps_network_cooldown_active &&
       gps_network_poll_due
    then
        gps_mark_network_poll

        if gps_try_provider "network"; then
            gps_apply_output "$GPS_LAST_OUTPUT" "network"

            if [ "${GPS_LAST_SOURCE:-}" = "GPS_CACHE_PRESERVED" ]; then
                GPS_STATUS="GPS_CACHE_PRESERVED"
                return 0
            fi

            if awk -v a="$GPS_ACC" \
                'BEGIN { exit !(a <= '"$network_max"') }'
            then
                GPS_STATUS="LIVE_NETWORK"
                return 0
            fi

            GPS_STATUS="LIVE_NETWORK_PROBE_WAIT"
            return 0
        fi

        GPS_API_ERRORS=$((GPS_API_ERRORS + 1))

        if [ "${GPS_LAST_RC:-0}" -eq 124 ]; then
            GPS_TIMEOUTS=$((GPS_TIMEOUTS + 1))
            gps_set_network_cooldown
        fi
    fi

    # ==================================================
    # 4. Any usable cache
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
