#!/data/data/com.termux/files/usr/bin/bash

THERMAL_STATUS="STARTING"
THERMAL_TEMP="--"

thermal_guard() {

    local temp="${BATTERY_TEMP:-}"

    THERMAL_STATUS="CHECKING"
    THERMAL_TEMP="--"

    # ไม่มีข้อมูล
    if [ -z "$temp" ] || [ "$temp" = "--" ]; then
        THERMAL_STATUS="NO_DATA"
        return 1
    fi

    # ต้องเป็นตัวเลขจริงเท่านั้น
    if ! awk -v t="$temp" \
        'BEGIN {
            exit !(t ~ /^[0-9]+([.][0-9]+)?$/)
        }'
    then
        THERMAL_STATUS="INVALID_DATA"
        return 1
    fi

    THERMAL_TEMP="$temp"

    if awk -v t="$THERMAL_TEMP" \
        -v c="${TEMP_CRITICAL:-55}" \
        'BEGIN { exit !(t >= c) }'
    then

        THERMAL_STATUS="CRITICAL"

    elif awk -v t="$THERMAL_TEMP" \
        -v h="${TEMP_HIGH:-48}" \
        'BEGIN { exit !(t >= h) }'
    then

        THERMAL_STATUS="HIGH"

    elif awk -v t="$THERMAL_TEMP" \
        -v w="${TEMP_WARNING:-42}" \
        'BEGIN { exit !(t >= w) }'
    then

        THERMAL_STATUS="WARNING"

    else

        THERMAL_STATUS="NORMAL"

    fi

    printf '%s\n' \
        "$THERMAL_STATUS temp=$THERMAL_TEMP time=$(date +%s)" \
        > "$STATE_DIR/thermal.state"

    return 0
}
