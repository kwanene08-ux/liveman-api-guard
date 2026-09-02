#!/data/data/com.termux/files/usr/bin/bash

show_ui() {

    clear

    printf '==================================================\n'
    printf ' LIVE MAN API GUARD %s\n' "$VERSION"
    printf '==================================================\n\n'

    printf ' Round            : #%s\n' "$ROUND"
    printf ' Heartbeat        : %s\n' "$HEARTBEAT"

    printf '\n'

    printf ' GPS              : %s\n' "$GPS_STATUS"
    printf ' Accuracy         : %sm\n' "${GPS_ACC:---}"

    printf ' Network          : %s\n' "$NETWORK_STATUS"
    printf ' Ping             : %sms\n' "${NETWORK_PING:---}"

    printf '\n'

    printf ' Battery          : %s\n' "$BATTERY_STATUS"
    printf ' Percent          : %s%%\n' "${BATTERY_PERCENT:---}"

    printf ' Temperature      : %s°C\n' "${BATTERY_TEMP:---}"
    printf ' Thermal          : %s\n' "$THERMAL_STATUS"

    printf '\n'

    printf ' Watchdog         : %s\n' "$WATCHDOG_STATUS"
    printf ' Self Test        : %s\n' "$SELFTEST_STATUS"

    printf '\n'

    printf ' Auto Recovery    : %s\n' "$AUTO_RECOVERY"

    printf '\nCtrl+C เพื่อหยุดระบบ\n'

    printf '==================================================\n'
}
