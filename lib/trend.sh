#!/data/data/com.termux/files/usr/bin/bash

history_append() {

    local file="$1"
    local value="$2"
    local size="${3:-10}"
    local tmp="${file}.tmp"

    if ! awk -v v="$value" \
        'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/) }'
    then
        return 1
    fi

    mkdir -p "$(dirname "$file")"

    {
        cat "$file" 2>/dev/null || true
        echo "$value"
    } | tail -n "$size" > "$tmp"

    mv "$tmp" "$file"
}


history_average() {

    local file="$1"

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


history_trend() {

    local file="$1"

    if [ ! -s "$file" ]; then
        echo "UNKNOWN"
        return
    fi

    local count
    count="$(grep -Ec '^[0-9]+([.][0-9]+)?$' "$file" 2>/dev/null || echo 0)"

    if [ "$count" -lt 4 ]; then
        echo "STABLE"
        return
    fi

    local old_avg
    local new_avg

    old_avg="$(
        head -n "$((count / 2))" "$file" |
        awk '
            /^[0-9]+([.][0-9]+)?$/ {
                sum += $1
                n++
            }
            END {
                if (n > 0)
                    printf "%.2f", sum / n
                else
                    print "0"
            }
        '
    )"

    new_avg="$(
        tail -n "$((count / 2))" "$file" |
        awk '
            /^[0-9]+([.][0-9]+)?$/ {
                sum += $1
                n++
            }
            END {
                if (n > 0)
                    printf "%.2f", sum / n
                else
                    print "0"
            }
        '
    )"

    local diff

    diff="$(
        awk -v o="$old_avg" -v n="$new_avg" \
        'BEGIN { printf "%.2f", n-o }'
    )"

    if awk -v d="$diff" \
        'BEGIN { exit !(d > 10) }'
    then
        echo "RISING"

    elif awk -v d="$diff" \
        'BEGIN { exit !(d < -10) }'
    then
        echo "FALLING"

    else
        echo "STABLE"
    fi
}


network_trend_update() {

    local file="$STATE_DIR/network.trend.history"

    history_append \
        "$file" \
        "${NETWORK_PING:-}" \
        "${NETWORK_HISTORY_SIZE:-10}" \
        || return

    NETWORK_TREND="$(history_trend "$file")"
}


gps_trend_update() {

    local file="$STATE_DIR/gps.trend.history"

    history_append \
        "$file" \
        "${GPS_ACC:-}" \
        "${GPS_HISTORY_SIZE:-10}" \
        || return

    GPS_TREND="$(history_trend "$file")"
}


health_trend_update() {

    local file="$STATE_DIR/health.history"

    history_append \
        "$file" \
        "${SYSTEM_HEALTH_SCORE:-}" \
        "${HEALTH_HISTORY_SIZE:-10}" \
        || return

    HEALTH_TREND="$(history_trend "$file")"
}
