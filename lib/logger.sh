#!/data/data/com.termux/files/usr/bin/bash

log_event() {

    local level="$1"
    shift

    local message="$*"

    printf '%s | %-7s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$level" \
        "$message" \
        >> "$LOG_CURRENT"

    if [ "$level" = "ERROR" ]; then

        printf '%s | %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$message" \
            >> "$LOG_ERROR"

    fi
}

rotate_logs() {

    local max="${LOG_MAX_LINES:-5000}"

    if [ -f "$LOG_CURRENT" ]; then

        local lines

        lines="$(wc -l < "$LOG_CURRENT" 2>/dev/null || echo 0)"

        if [ "$lines" -gt "$max" ]; then

            mv "$LOG_CURRENT" \
                "$LOG_ARCHIVE/current_$(date +%Y%m%d_%H%M%S).log"

            touch "$LOG_CURRENT"

        fi
    fi
}
