#!/data/data/com.termux/files/usr/bin/bash

SELFTEST_STATUS="STARTING"

selftest_run() {

    SELFTEST_STATUS="PASS"

    for cmd in \
        bash \
        jq \
        timeout \
        awk \
        grep
    do

        if ! have_cmd "$cmd"; then

            SELFTEST_STATUS="MISSING_$cmd"

            return 1

        fi

    done

    if ! have_cmd termux-battery-status; then

        SELFTEST_STATUS="TERMUX_API_WARNING"
    fi

    return 0
}
