#!/data/data/com.termux/files/usr/bin/bash

# ==================================================
# LIVE MAN API GUARD
# ENGINE SUPERVISOR v9.0
# ==================================================

ENGINE_DIR="$ROOT/engines"
ENGINE_PID_DIR="$STATE_DIR/pids"

SUPERVISOR_RESTARTS=0
SUPERVISOR_CRASHES=0
SUPERVISOR_RECOVERIES=0

mkdir -p "$ENGINE_PID_DIR"


engine_pid_file() {
    printf '%s/%s.pid\n' "$ENGINE_PID_DIR" "$1"
}


engine_running() {

    local name="$1"
    local pid_file
    local pid

    pid_file="$(engine_pid_file "$name")"

    [ -f "$pid_file" ] || return 1

    pid="$(tr -cd '0-9' < "$pid_file" 2>/dev/null || true)"

    [ -n "$pid" ] || return 1

    kill -0 "$pid" 2>/dev/null
}


engine_stop() {

    local name="$1"
    local pid_file
    local pid

    pid_file="$(engine_pid_file "$name")"

    if [ -f "$pid_file" ]; then

        pid="$(tr -cd '0-9' < "$pid_file" 2>/dev/null || true)"

        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then

            kill -TERM "$pid" 2>/dev/null || true

            sleep 1

            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi

        fi
    fi

    rm -f "$pid_file" 2>/dev/null || true
}


engine_start() {

    local name="$1"
    local file="$ENGINE_DIR/$name.sh"
    local pid_file
    local pid

    pid_file="$(engine_pid_file "$name")"

    # Prevent duplicate engine processes
    if engine_running "$name"; then
        pid="$(tr -cd '0-9' < "$pid_file" 2>/dev/null || true)"
        log "ENGINE_ALREADY_RUNNING name=$name pid=$pid"
        return 0
    fi

    # Remove stale PID file before starting
    rm -f "$pid_file" 2>/dev/null || true

    if [ ! -f "$file" ]; then

        SUPERVISOR_CRASHES=$((SUPERVISOR_CRASHES + 1))

        error_log "ENGINE_FILE_MISSING_$name"

        return 1
    fi


    if ! bash -n "$file"; then

        SUPERVISOR_CRASHES=$((SUPERVISOR_CRASHES + 1))

        error_log "ENGINE_SYNTAX_ERROR_$name"

        return 1
    fi


    bash "$file" &

    local pid=$!

    printf '%s\n' "$pid" > "$pid_file"


    SUPERVISOR_RESTARTS=$((SUPERVISOR_RESTARTS + 1))

    log "ENGINE_STARTED name=$name pid=$pid"

    return 0
}


engine_check() {

    local name="$1"

    if engine_running "$name"; then
        return 0
    fi

    SUPERVISOR_CRASHES=$((SUPERVISOR_CRASHES + 1))

    log "ENGINE_NOT_RUNNING name=$name"

    engine_stop "$name"

    sleep 1

    engine_start "$name" && \
        SUPERVISOR_RECOVERIES=$((SUPERVISOR_RECOVERIES + 1))
}


supervisor_check_all() {

    engine_check gps_guard

    engine_check network_guard

    engine_check battery_guard

    engine_check thermal_guard

    engine_check watchdog

}


supervisor_stop_all() {

    local engine

    for engine in \
        gps_guard \
        network_guard \
        battery_guard \
        thermal_guard \
        watchdog
    do

        engine_stop "$engine"

    done

    rm -rf "$ENGINE_PID_DIR" 2>/dev/null || true
}
