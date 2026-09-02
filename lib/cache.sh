#!/data/data/com.termux/files/usr/bin/bash

cache_save() {

    local file="$1"
    shift

    printf '%s\n' "$*" > "$file"
}

cache_read() {

    local file="$1"

    [ -f "$file" ] || return 1

    cat "$file"
}

cache_age() {

    local file="$1"

    [ -f "$file" ] || {
        echo "--"
        return
    }

    local now
    local modified

    now="$(date +%s)"

    modified="$(stat -c %Y "$file" 2>/dev/null || echo 0)"

    echo $((now - modified))
}
