#!/data/data/com.termux/files/usr/bin/bash

API_GUARD_SUCCESS="${API_GUARD_SUCCESS:-0}"
API_GUARD_CONSECUTIVE="${API_GUARD_CONSECUTIVE:-0}"
API_GUARD_LAST="${API_GUARD_LAST:-NONE}"
API_GUARD_LAST_TIME="${API_GUARD_LAST_TIME:---}"

API_GUARD_LOG_DIR="${LOG_DIR:-${ROOT:-$PWD}/logs}"
API_GUARD_STATE_DIR="${STATE_DIR:-${ROOT:-$PWD}/state}"

# ==================================================
# LOAD API CONFIG WHEN THIS LIBRARY IS USED STANDALONE
# Preserve values already supplied by rider.sh/caller.
# ==================================================

API_CONFIG_FILE="${ROOT:-$PWD}/config/config.conf"

if [ -f "$API_CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            API_TIMEOUT|API_RETRIES|API_LOCATION_TIMEOUT|API_BATTERY_TIMEOUT|API_NETWORK_LOCATION_TIMEOUT|API_LOCATION_COOLDOWN|API_BATTERY_COOLDOWN)
                if [ -z "${!key+x}" ]; then
                    printf -v "$key" '%s' "$value"
                fi
                ;;
        esac
    done < <(
        awk -F= '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*$/ { next }
            {
                key=$1
                value=$0
                sub(/^[[:space:]]*/, "", key)
                sub(/[[:space:]]*$/, "", key)
                sub(/^[^=]*=/, "", value)
                sub(/^[[:space:]]*/, "", value)
                sub(/[[:space:]]*$/, "", value)
                if (key != "") print key "=" value
            }
        ' "$API_CONFIG_FILE"
    )
fi

mkdir -p "$API_GUARD_LOG_DIR" "$API_GUARD_STATE_DIR" 2>/dev/null || true

API_LOCATION_COOLDOWN="${API_LOCATION_COOLDOWN:-30}"
API_BATTERY_COOLDOWN="${API_BATTERY_COOLDOWN:-30}"

API_LOCATION_COOLDOWN_FILE="$API_GUARD_STATE_DIR/api_location_cooldown"
API_BATTERY_COOLDOWN_FILE="$API_GUARD_STATE_DIR/api_battery_cooldown"

API_LOCATION_FAIL_FILE="$API_GUARD_STATE_DIR/api_location_failures"
API_BATTERY_FAIL_FILE="$API_GUARD_STATE_DIR/api_battery_failures"

# V8.9.6 provider isolation
API_GPS_COOLDOWN_FILE="$API_GUARD_STATE_DIR/api_gps_cooldown"
API_NETWORK_COOLDOWN_FILE="$API_GUARD_STATE_DIR/api_network_location_cooldown"

API_GPS_FAIL_FILE="$API_GUARD_STATE_DIR/api_gps_failures"
API_NETWORK_FAIL_FILE="$API_GUARD_STATE_DIR/api_network_location_failures"

# ==================================================
# V8.9.5 GLOBAL API SINGLE-FLIGHT LOCK
# ==================================================

API_SINGLE_LOCK_DIR="$API_GUARD_STATE_DIR/api_single.lock"
API_SINGLE_LOCK_WAIT="${API_SINGLE_LOCK_WAIT:-12}"

api_guard_log() {
    local message="$*"

    printf '%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$message" \
        >> "$API_GUARD_LOG_DIR/api_guard.log" 2>/dev/null || true
}

api_read_number_file() {
    local file="$1"
    local value

    value="$(cat "$file" 2>/dev/null || echo 0)"

    case "$value" in
        ''|*[!0-9]*)
            echo 0
            ;;
        *)
            echo "$value"
            ;;
    esac
}

api_write_number_file() {
    local file="$1"
    local value="$2"
    local tmp="$file.tmp.$$"

    printf '%s\n' "$value" > "$tmp" 2>/dev/null &&
        mv -f "$tmp" "$file" 2>/dev/null || true
}

api_single_lock_acquire() {
    local waited=0
    local owner_pid="0"

    while ! mkdir "$API_SINGLE_LOCK_DIR" 2>/dev/null; do

        if [ -s "$API_SINGLE_LOCK_DIR/pid" ]; then
            owner_pid="$(api_read_number_file "$API_SINGLE_LOCK_DIR/pid")"

            if [ "$owner_pid" -gt 1 ] &&
               ! kill -0 "$owner_pid" 2>/dev/null
            then
                rm -rf "$API_SINGLE_LOCK_DIR" 2>/dev/null || true
                continue
            fi
        fi

        if [ "$waited" -ge "$API_SINGLE_LOCK_WAIT" ]; then
            api_guard_log "API_SINGLE_LOCK_BUSY waited=${waited}s"
            return 125
        fi

        sleep 1
        waited=$((waited + 1))
    done

    printf '%s\n' "$$" > "$API_SINGLE_LOCK_DIR/pid" 2>/dev/null || true

    api_guard_log "API_SINGLE_LOCK_ACQUIRED pid=$$"
    return 0
}

api_single_lock_release() {
    if [ -d "$API_SINGLE_LOCK_DIR" ]; then
        rm -f "$API_SINGLE_LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$API_SINGLE_LOCK_DIR" 2>/dev/null ||
            rm -rf "$API_SINGLE_LOCK_DIR" 2>/dev/null || true

        api_guard_log "API_SINGLE_LOCK_RELEASED pid=$$"
    fi
}

api_single_lock_force_cleanup() {
    local owner_pid="0"

    if [ -s "$API_SINGLE_LOCK_DIR/pid" ]; then
        owner_pid="$(api_read_number_file "$API_SINGLE_LOCK_DIR/pid")"
    fi

    if [ "$owner_pid" -eq "$$" ] ||
       { [ "$owner_pid" -gt 1 ] &&
         ! kill -0 "$owner_pid" 2>/dev/null; }
    then
        rm -rf "$API_SINGLE_LOCK_DIR" 2>/dev/null || true
    fi
}

api_provider_for_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            network)
                printf '%s\n' "network"
                return 0
                ;;
            gps)
                printf '%s\n' "gps"
                return 0
                ;;
        esac
    done
    printf '%s\n' "default"
}

api_cooldown_file_for_request() {
    local cmd="$1"
    shift

    case "$cmd" in
        termux-location)
            case "$(api_provider_for_args "$@")" in
                gps)
                    printf '%s\n' "$API_GPS_COOLDOWN_FILE"
                    ;;
                network)
                    printf '%s\n' "$API_NETWORK_COOLDOWN_FILE"
                    ;;
                *)
                    printf '%s\n' "$API_LOCATION_COOLDOWN_FILE"
                    ;;
            esac
            ;;
        termux-battery-status)
            printf '%s\n' "$API_BATTERY_COOLDOWN_FILE"
            ;;
        *)
            printf '\n'
            ;;
    esac
}

api_failure_file_for_request() {
    local cmd="$1"
    shift

    case "$cmd" in
        termux-location)
            case "$(api_provider_for_args "$@")" in
                gps)
                    printf '%s\n' "$API_GPS_FAIL_FILE"
                    ;;
                network)
                    printf '%s\n' "$API_NETWORK_FAIL_FILE"
                    ;;
                *)
                    printf '%s\n' "$API_LOCATION_FAIL_FILE"
                    ;;
            esac
            ;;
        termux-battery-status)
            printf '%s\n' "$API_BATTERY_FAIL_FILE"
            ;;
        *)
            printf '\n'
            ;;
    esac
}

api_base_cooldown_for_request() {
    local cmd="$1"
    shift

    case "$cmd" in
        termux-location)
            case "$(api_provider_for_args "$@")" in
                gps)
                    printf '%s\n' "${API_LOCATION_COOLDOWN:-30}"
                    ;;
                network)
                    printf '%s\n' "${API_LOCATION_COOLDOWN:-30}"
                    ;;
                *)
                    printf '%s\n' "${API_LOCATION_COOLDOWN:-30}"
                    ;;
            esac
            ;;
        termux-battery-status)
            printf '%s\n' "${API_BATTERY_COOLDOWN:-30}"
            ;;
        *)
            printf '0\n'
            ;;
    esac
}

api_cmd_cooldown_active() {
    local cmd="$1"
    shift

    local file
    local now
    local until

    file="$(api_cooldown_file_for_request "$cmd" "$@")"

    [ -n "$file" ] || return 1
    [ -s "$file" ] || return 1

    until="$(api_read_number_file "$file")"
    now="$(date +%s)"

    if [ "$until" -gt "$now" ]; then
        return 0
    fi

    rm -f "$file" 2>/dev/null || true
    return 1
}

api_set_cmd_cooldown() {
    local cmd="$1"
    shift

    local file
    local fail_file
    local base
    local failures
    local cooldown
    local until
    local provider

    provider="$(api_provider_for_args "$@")"

    file="$(api_cooldown_file_for_request "$cmd" "$@")"
    fail_file="$(api_failure_file_for_request "$cmd" "$@")"

    [ -n "$file" ] || return 0
    [ -n "$fail_file" ] || return 0

    base="$(api_base_cooldown_for_request "$cmd" "$@")"
    failures="$(api_read_number_file "$fail_file")"
    failures=$((failures + 1))

    case "$failures" in
        1) cooldown="$base" ;;
        2) cooldown=$((base * 2)) ;;
        *) cooldown=$((base * 4)) ;;
    esac

    [ "$cooldown" -gt 120 ] && cooldown=120

    api_write_number_file "$fail_file" "$failures"

    until=$(( $(date +%s) + cooldown ))
    api_write_number_file "$file" "$until"

    api_guard_log \
        "API_COOLDOWN_SET provider=$provider command=$cmd failures=$failures seconds=$cooldown until=$until"
}

api_clear_cmd_failure() {
    local cmd="$1"
    shift

    local file

    file="$(api_failure_file_for_request "$cmd" "$@")"
    [ -n "$file" ] || return 0

    rm -f "$file" 2>/dev/null || true
}

api_clear_expired_cooldowns() {
    local file
    local now
    local until

    now="$(date +%s)"

    for file in \
        "$API_LOCATION_COOLDOWN_FILE" \
        "$API_BATTERY_COOLDOWN_FILE" \
        "$API_GPS_COOLDOWN_FILE" \
        "$API_NETWORK_COOLDOWN_FILE"
    do
        [ -s "$file" ] || continue

        until="$(api_read_number_file "$file")"

        if [ "$until" -le "$now" ]; then
            rm -f "$file" 2>/dev/null || true
        fi
    done
}

api_silent() {
    [ "$#" -ge 1 ] || {
        API_GUARD_LAST="ERROR"
        API_GUARD_LAST_TIME="$(date '+%H:%M:%S')"
        api_guard_log "API_ERROR no_command"
        return 2
    }

    local cmd="$1"
    shift

    local timeout_sec
    local rc
    local arg
    local provider=""

    api_clear_expired_cooldowns

    provider="$(api_provider_for_args "$@")"

    if api_cmd_cooldown_active "$cmd" "$@"; then
        API_GUARD_LAST="COOLDOWN"
        API_GUARD_LAST_TIME="$(date '+%H:%M:%S')"
        api_guard_log "API_COOLDOWN provider=$provider command=$cmd"
        return 125
    fi

    case "$cmd" in
        termux-location)
            timeout_sec="${API_LOCATION_TIMEOUT:-8}"

            if [ "$provider" = "network" ]; then
                timeout_sec="${API_NETWORK_LOCATION_TIMEOUT:-6}"
            fi
            ;;
        termux-battery-status)
            timeout_sec="${API_BATTERY_TIMEOUT:-6}"
            ;;
        *)
            timeout_sec="${API_TIMEOUT:-10}"
            ;;
    esac

    if ! command -v "$cmd" >/dev/null 2>&1; then
        API_GUARD_LAST="COMMAND_MISSING"
        API_GUARD_LAST_TIME="$(date '+%H:%M:%S')"
        API_GUARD_CONSECUTIVE=$((API_GUARD_CONSECUTIVE + 1))
        api_guard_log "API_COMMAND_MISSING provider=$provider command=$cmd"
        return 127
    fi

    if ! api_single_lock_acquire; then
        API_GUARD_LAST="BUSY"
        API_GUARD_LAST_TIME="$(date '+%H:%M:%S')"
        return 125
    fi

    # V12: isolate API timeout TERM from rider.sh cleanup trap.
    # termux-location may receive TERM through timeout; never let that
    # terminate the parent LIVE MAN supervisor.
    local saved_term_trap
    saved_term_trap="$(trap -p TERM || true)"

    trap '' TERM

    timeout \
        --signal=TERM \
        --kill-after=2 \
        "$timeout_sec" \
        "$cmd" "$@" \
        2>>"$API_GUARD_LOG_DIR/api_error.log"

    rc=$?

    if [ -n "$saved_term_trap" ]; then
        eval "$saved_term_trap"
    else
        trap - TERM
    fi

    api_single_lock_release

    if [ "$rc" -eq 0 ]; then
        API_GUARD_SUCCESS=$((API_GUARD_SUCCESS + 1))
        API_GUARD_CONSECUTIVE=0
        API_GUARD_LAST="NONE"
        API_GUARD_LAST_TIME="--"

        api_clear_cmd_failure "$cmd" "$@"
        return 0
    fi

    API_GUARD_CONSECUTIVE=$((API_GUARD_CONSECUTIVE + 1))
    API_GUARD_LAST_TIME="$(date '+%H:%M:%S')"

    if [ "$rc" -eq 124 ]; then
        API_GUARD_LAST="TIMEOUT"
        api_guard_log \
            "API_TIMEOUT ${timeout_sec}s provider=$provider command=$cmd $*"
        api_set_cmd_cooldown "$cmd" "$@"
    elif [ "$rc" -eq 125 ]; then
        API_GUARD_LAST="COOLDOWN"
    else
        API_GUARD_LAST="ERROR"
        api_guard_log \
            "API_ERROR rc=$rc provider=$provider command=$cmd $*"
    fi

    return "$rc"
}

api_location() {
    api_silent termux-location "$@"
}

api_battery() {
    api_silent termux-battery-status "$@"
}

api_cmd_health() {
    local cmd="$1"
    local cooldown_file
    local fail_file
    local failures
    local now
    local until

    cooldown_file="$(api_cooldown_file_for_cmd "$cmd")"
    fail_file="$(api_failure_file_for_cmd "$cmd")"
    failures="$(api_read_number_file "$fail_file")"
    now="$(date +%s)"
    until="$(api_read_number_file "$cooldown_file")"

    if [ "$until" -gt "$now" ]; then
        printf 'COOLDOWN\n'
        return 0
    fi

    if [ "$failures" -gt 0 ]; then
        printf 'RECOVERING\n'
        return 0
    fi

    printf 'READY\n'
}

api_location_health() {
    api_cmd_health termux-location
}

api_battery_health() {
    api_cmd_health termux-battery-status
}

api_health_overall() {
    local loc
    local bat

    loc="$(api_location_health)"
    bat="$(api_battery_health)"

    if [ "$loc" = "COOLDOWN" ] && [ "$bat" = "COOLDOWN" ]; then
        printf 'COOLDOWN\n'
    elif [ "$loc" = "COOLDOWN" ] || [ "$bat" = "COOLDOWN" ]; then
        printf 'DEGRADED\n'
    elif [ "$loc" = "RECOVERING" ] || [ "$bat" = "RECOVERING" ]; then
        printf 'RECOVERING\n'
    else
        printf 'READY\n'
    fi
}

api_guard_status() {
    if [ "${API_GUARD_CONSECUTIVE:-0}" -ge 5 ]; then
        echo "CRITICAL"
    elif [ "${API_GUARD_CONSECUTIVE:-0}" -ge 2 ]; then
        echo "WARNING"
    else
        echo "NORMAL"
    fi
}

api_guard_reset() {
    API_GUARD_CONSECUTIVE=0
    API_GUARD_LAST="NONE"
    API_GUARD_LAST_TIME="--"
}

api_guard_cleanup() {
    rm -f \
        "$API_LOCATION_COOLDOWN_FILE" \
        "$API_BATTERY_COOLDOWN_FILE" \
        "$API_LOCATION_FAIL_FILE" \
        "$API_BATTERY_FAIL_FILE" \
        "$API_LOCATION_COOLDOWN_FILE.tmp."* \
        "$API_BATTERY_COOLDOWN_FILE.tmp."* \
        2>/dev/null || true

    api_single_lock_force_cleanup
}
