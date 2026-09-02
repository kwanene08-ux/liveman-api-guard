#!/data/data/com.termux/files/usr/bin/bash

diagnose_api() {

    local command="$1"

    if ! command -v "$command" >/dev/null 2>&1; then

        echo "COMMAND_MISSING"

        return
    fi

    echo "COMMAND_AVAILABLE"
}

diagnose_json() {

    local json="$1"

    if [ -z "$json" ]; then

        echo "EMPTY_RESPONSE"

        return

    fi

    if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then

        echo "INVALID_JSON"

        return

    fi

    echo "JSON_OK"
}
