#!/data/data/com.termux/files/usr/bin/bash

gps_cache_age() {

    local file="$STATE_DIR/gps.state"
    local now
    local mtime

    if [ ! -s "$file" ]; then
        echo "--"
        return
    fi

    now="$(date +%s)"
    mtime="$(stat -c %Y "$file" 2>/dev/null || echo "")"

    if [ -z "$mtime" ]; then
        echo "--"
        return
    fi

    if [ "$now" -lt "$mtime" ]; then
        echo "0"
        return
    fi

    echo $((now - mtime))
}


gps_health_score() {

    local status="${GPS_STATUS:-UNKNOWN}"
    local accuracy="${GPS_ACC:-}"
    local cache_age

    cache_age="$(gps_cache_age)"

    case "$status" in

        LIVE|LIVE_GPS)

            if ! awk -v a="$accuracy" \
                'BEGIN {
                    exit !(a ~ /^[0-9]+([.][0-9]+)?$/)
                }'
            then
                echo 0
                return
            fi

            if awk -v a="$accuracy" \
                -v g="${GPS_GOOD_ACCURACY:-10}" \
                'BEGIN { exit !(a <= g) }'
            then
                echo 100

            elif awk -v a="$accuracy" \
                -v w="${GPS_WARNING_ACCURACY:-30}" \
                'BEGIN { exit !(a <= w) }'
            then
                echo 85

            elif awk -v a="$accuracy" \
                -v b="${GPS_BAD_ACCURACY:-50}" \
                'BEGIN { exit !(a <= b) }'
            then
                echo 60

            else
                echo 30
            fi
            ;;

        CACHE)

            if [ "$cache_age" != "--" ] &&
               awk -v a="$cache_age" \
                   'BEGIN { exit !(a ~ /^[0-9]+$/) }' &&
               [ "$cache_age" -le "${GPS_CACHE_MAX_AGE:-60}" ]
            then
                echo 70
            else
                echo 30
            fi
            ;;

        *)
            echo 0
            ;;
    esac
}

battery_health_score() {

    case "${BATTERY_STATUS:-UNKNOWN}" in
        LIVE)
            echo 100
            ;;
        CACHE)
            echo 70
            ;;
        *)
            echo 0
            ;;
    esac
}


network_health_score() {

    local status="${NETWORK_STATUS:-UNKNOWN}"
    local stability="${HEALTH_NET_STABILITY:-}"

    if [ -z "$stability" ]; then
        stability="$(network_stability)"
    fi

    case "$status" in

        GOOD)

            case "$stability" in
                STABLE)
                    echo "${NETWORK_SCORE_GOOD_STABLE:-100}"
                    ;;
                VARIABLE)
                    echo "${NETWORK_SCORE_GOOD_VARIABLE:-85}"
                    ;;
                UNSTABLE)
                    echo "${NETWORK_SCORE_GOOD_UNSTABLE:-65}"
                    ;;
                *)
                    echo "${NETWORK_SCORE_GOOD_VARIABLE:-85}"
                    ;;
            esac
            ;;

        WARNING)

            case "$stability" in
                STABLE)
                    echo "${NETWORK_SCORE_WARNING_STABLE:-70}"
                    ;;
                VARIABLE)
                    echo "${NETWORK_SCORE_WARNING_VARIABLE:-55}"
                    ;;
                UNSTABLE)
                    echo "${NETWORK_SCORE_WARNING_UNSTABLE:-40}"
                    ;;
                *)
                    echo "${NETWORK_SCORE_WARNING_VARIABLE:-55}"
                    ;;
            esac
            ;;

        BAD)
            echo "${NETWORK_SCORE_BAD:-40}"
            ;;

        OFFLINE|OFFLINE_CACHE)
            echo "${NETWORK_SCORE_OFFLINE:-0}"
            ;;

        *)
            echo 0
            ;;
    esac
}


thermal_health_score() {

    case "${THERMAL_STATUS:-UNKNOWN}" in
        NORMAL)
            echo 100
            ;;
        WARNING)
            echo 70
            ;;
        HIGH)
            echo 40
            ;;
        CRITICAL)
            echo 0
            ;;
        *)
            echo 0
            ;;
    esac
}


network_history_update() {

    local file="$STATE_DIR/network.history"
    local tmp="$STATE_DIR/network.history.tmp"
    local ping="${NETWORK_PING:-}"

    if ! awk -v p="$ping" \
        'BEGIN { exit !(p ~ /^[0-9]+([.][0-9]+)?$/) }'
    then
        return
    fi

    touch "$file"

    {
        cat "$file" 2>/dev/null
        echo "$ping"
    } | tail -n 10 > "$tmp"

    mv "$tmp" "$file"
}


network_average_ping() {

    local file="$STATE_DIR/network.history"

    if [ ! -s "$file" ]; then
        echo "--"
        return
    fi

    awk '
        /^[0-9]+([.][0-9]+)?$/ {
            sum += $1
            count++
        }

        END {
            if (count > 0)
                printf "%.1f", sum / count
            else
                print "--"
        }
    ' "$file"
}


network_stability() {

    local file="$STATE_DIR/network.history"
    local avg
    local max
    local min
    local diff

    if [ ! -s "$file" ]; then
        echo "UNKNOWN"
        return
    fi

    avg="$(network_average_ping)"

    if [ "$avg" = "--" ]; then
        echo "UNKNOWN"
        return
    fi

    max="$(sort -n "$file" | tail -n 1)"
    min="$(sort -n "$file" | head -n 1)"

    diff="$(awk -v a="$max" -v b="$min" \
        'BEGIN { printf "%.1f", a-b }')"

    if awk -v d="$diff" 'BEGIN { exit !(d <= 20) }'
    then
        echo "STABLE"

    elif awk -v d="$diff" 'BEGIN { exit !(d <= 60) }'
    then
        echo "VARIABLE"

    else
        echo "UNSTABLE"
    fi
}


system_health_score() {

    local gps
    local battery
    local network
    local thermal

    gps="$(gps_health_score)"
    battery="$(battery_health_score)"
    network="$(network_health_score)"
    thermal="$(thermal_health_score)"

    awk \
        -v g="$gps" \
        -v b="$battery" \
        -v n="$network" \
        -v t="$thermal" \
        'BEGIN {
            printf "%.0f", (g+b+n+t)/4
        }'
}


system_health_status() {

    local score="$1"

    if [ "$score" -ge 90 ]; then
        echo "EXCELLENT"

    elif [ "$score" -ge 75 ]; then
        echo "GOOD"

    elif [ "$score" -ge 50 ]; then
        echo "WARNING"

    else
        echo "CRITICAL"
    fi
}
