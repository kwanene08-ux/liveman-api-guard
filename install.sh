#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/bin"

echo
echo "=================================================="
echo " LIVE MAN API GUARD - ONE COMMAND INSTALLER"
echo "=================================================="
echo

# ==================================================
# CREATE DIRECTORIES
# ==================================================

echo "[1/8] Preparing directories..."

mkdir -p \
    "$ROOT/engines" \
    "$ROOT/lib" \
    "$ROOT/config" \
    "$ROOT/state" \
    "$ROOT/logs/archive" \
    "$ROOT/backup" \
    "$ROOT/update" \
    "$ROOT/tmp" \
    "$BIN"

chmod 700 \
    "$ROOT/state" \
    "$ROOT/tmp" \
    "$ROOT/backup" 2>/dev/null || true

echo "PASS: Directories ready"


# ==================================================
# DEPENDENCIES
# ==================================================

echo
echo "[2/8] Checking dependencies..."

MISSING_PKGS=""

check_cmd() {

    local cmd="$1"
    local pkg="$2"

    if command -v "$cmd" >/dev/null 2>&1; then
        echo "PASS: $cmd"
    else
        echo "MISSING: $cmd"
        MISSING_PKGS="$MISSING_PKGS $pkg"
    fi
}

check_cmd bash bash
check_cmd jq jq
check_cmd timeout coreutils
check_cmd awk gawk
check_cmd grep grep
check_cmd ping iputils

if ! command -v termux-battery-status >/dev/null 2>&1; then
    echo "MISSING: termux-battery-status"
    MISSING_PKGS="$MISSING_PKGS termux-api"
else
    echo "PASS: termux-battery-status"
fi

if ! command -v termux-location >/dev/null 2>&1; then
    echo "MISSING: termux-location"
    MISSING_PKGS="$MISSING_PKGS termux-api"
else
    echo "PASS: termux-location"
fi


if [ -n "$MISSING_PKGS" ]; then

    echo
    echo "Installing required packages..."

    pkg update -y

    PKGS="$(printf '%s\n' $MISSING_PKGS | sort -u | tr '\n' ' ')"

    pkg install -y $PKGS

else

    echo "PASS: Dependencies already installed"

fi


# ==================================================
# PERMISSIONS
# ==================================================

echo
echo "[3/8] Setting permissions..."

find "$ROOT" \
    -type f \
    -name "*.sh" \
    -exec chmod 700 {} \;

chmod 700 \
    "$ROOT/rider.sh" \
    "$ROOT/stop.sh" \
    "$ROOT/update.sh" \
    "$ROOT/rollback.sh" \
    "$ROOT/install.sh" 2>/dev/null || true

echo "PASS: Permissions ready"


# ==================================================
# CREATE COMMANDS
# ==================================================

echo
echo "[4/8] Creating commands..."

cat > "$BIN/rider" <<EOF2
#!/data/data/com.termux/files/usr/bin/bash
exec bash "$ROOT/rider.sh"
EOF2


cat > "$BIN/stop" <<EOF2
#!/data/data/com.termux/files/usr/bin/bash
exec bash "$ROOT/stop.sh"
EOF2


cat > "$BIN/update" <<EOF2
#!/data/data/com.termux/files/usr/bin/bash
exec bash "$ROOT/update.sh"
EOF2


cat > "$BIN/rollback" <<EOF2
#!/data/data/com.termux/files/usr/bin/bash
exec bash "$ROOT/rollback.sh"
EOF2


cat > "$BIN/preflight" <<EOF2
#!/data/data/com.termux/files/usr/bin/bash
exec bash "$ROOT/preflight.sh"
EOF2


chmod 700 \
    "$BIN/rider" \
    "$BIN/stop" \
    "$BIN/update" \
    "$BIN/rollback" \
    "$BIN/preflight"

echo "PASS: Commands created"


# ==================================================
# PATH
# ==================================================

echo
echo "[5/8] Checking PATH..."

PATH_LINE='export PATH="$HOME/bin:$PATH"'

if [ -f "$HOME/.bashrc" ]; then

    if ! grep -qxF "$PATH_LINE" "$HOME/.bashrc"; then
        echo "$PATH_LINE" >> "$HOME/.bashrc"
        echo "PATH ADDED"
    else
        echo "PATH ALREADY CONFIGURED"
    fi

else

    echo "$PATH_LINE" > "$HOME/.bashrc"

fi


export PATH="$HOME/bin:$PATH"

hash -r

echo "RIDER COMMAND: $(command -v rider || echo NOT_FOUND)"
echo "STOP COMMAND : $(command -v stop || echo NOT_FOUND)"


# ==================================================
# SYNTAX TEST
# ==================================================

echo
echo "[6/8] Running syntax test..."

ERRORS=0
TOTAL=0

while IFS= read -r -d '' FILE
do

    TOTAL=$((TOTAL + 1))

    if bash -n "$FILE"; then
        echo "PASS: $FILE"
    else
        echo "FAIL: $FILE"
        ERRORS=$((ERRORS + 1))
    fi

done < <(
    find "$ROOT" \
        -type f \
        -name "*.sh" \
        -print0
)


echo
echo "Scripts checked : $TOTAL"
echo "Syntax errors   : $ERRORS"


if [ "$ERRORS" -ne 0 ]; then

    echo
    echo "=================================================="
    echo " INSTALL FAILED - FIX SYNTAX ERRORS FIRST"
    echo "=================================================="

    exit 1

fi


# ==================================================
# PROCESS CHECK
# ==================================================

echo
echo "[7/8] Checking old processes..."

OLD="$(pgrep -af 'rider\.sh' 2>/dev/null || true)"

if [ -n "$OLD" ]; then

    echo "WARNING: Existing rider process found"
    echo "$OLD"

else

    echo "PASS: No old rider process"

fi


# ==================================================
# PREFLIGHT
# ==================================================

echo
echo "[8/8] Running runtime preflight..."

if [ -f "$ROOT/preflight.sh" ]; then

    chmod 700 "$ROOT/preflight.sh"

    bash "$ROOT/preflight.sh"

    PREFLIGHT_RC=$?

else

    echo "WARNING: preflight.sh not found"
    PREFLIGHT_RC=1

fi


# ==================================================
# FINAL
# ==================================================

echo
echo "=================================================="

if [ "$PREFLIGHT_RC" -eq 0 ]; then

    echo " INSTALL COMPLETE"
    echo " SYSTEM READY"

else

    echo " INSTALL COMPLETE WITH PREFLIGHT WARNING"

fi

echo "=================================================="

echo
echo "Available commands:"
echo
echo "  rider      -> Start LIVE MAN API GUARD"
echo "  stop       -> Stop safely"
echo "  preflight  -> Test GPS / Battery / Network"
echo "  update     -> Update project"
echo "  rollback   -> Rollback version"
echo

echo "Start system with:"
echo
echo "  rider"
echo

