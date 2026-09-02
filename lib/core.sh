#!/data/data/com.termux/files/usr/bin/bash

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

now_epoch() {
    date +%s
}

now_time() {
    date '+%H:%M:%S'
}

now_datetime() {
    date '+%Y-%m-%d %H:%M:%S'
}

is_number() {
    printf '%s' "${1:-}" | grep -Eq '^[0-9]+([.][0-9]+)?$'
}

safe_kill() {

    local pid="${1:-}"

    [ -n "$pid" ] || return 1

    kill -0 "$pid" 2>/dev/null || return 0

    kill -TERM "$pid" 2>/dev/null || true

    for _ in 1 2 3 4 5; do

        kill -0 "$pid" 2>/dev/null || return 0

        sleep 1

    done

    kill -KILL "$pid" 2>/dev/null || true
}

atomic_lock() {

    local lock="$1"

    if mkdir "$lock" 2>/dev/null; then

        echo "$$" > "$lock/pid"

        return 0

    fi

    return 1
}

remove_lock() {

    local lock="$1"

    rm -rf "$lock" 2>/dev/null || true
}
