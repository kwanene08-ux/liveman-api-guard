#!/data/data/com.termux/files/usr/bin/bash

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1

TMP_DIR="$ROOT/tmp"
BACKUP_DIR="$ROOT/backup"
LOG_DIR="$ROOT/logs"

mkdir -p "$TMP_DIR" "$BACKUP_DIR" "$LOG_DIR"

log() {
    printf '%s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$1" >> "$LOG_DIR/update.log" 2>/dev/null || true
}

fail() {
    echo "FAIL: $1"
    log "FAIL: $1"
    exit 1
}

echo "=================================================="
echo " LIVE MAN API GUARD AUTO UPDATE"
echo "=================================================="

# --------------------------------------------------
# Basic Git checks
# --------------------------------------------------

command -v git >/dev/null 2>&1 ||
    fail "git not installed"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    fail "not a git repository"

REMOTE="$(git remote get-url origin 2>/dev/null || true)"

[ -n "$REMOTE" ] ||
    fail "origin remote missing"

echo "REMOTE : $REMOTE"

# --------------------------------------------------
# Prevent overwrite of local modifications
# --------------------------------------------------

if [ -n "$(git status --porcelain)" ]; then
    echo
    echo "LOCAL CHANGES DETECTED:"
    git status --short
    fail "working tree is not clean"
fi

OLD_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
OLD_VERSION="$(cat VERSION 2>/dev/null || echo UNKNOWN)"

[ -n "$OLD_COMMIT" ] ||
    fail "current commit not found"

echo "CURRENT VERSION : $OLD_VERSION"
echo "CURRENT COMMIT  : $OLD_COMMIT"

# --------------------------------------------------
# Fetch
# --------------------------------------------------

echo
echo "===== FETCH ====="

git fetch --prune origin ||
    fail "git fetch failed"

REMOTE_COMMIT="$(git rev-parse origin/main 2>/dev/null || true)"

[ -n "$REMOTE_COMMIT" ] ||
    fail "origin/main not found"

echo "REMOTE COMMIT   : $REMOTE_COMMIT"

# --------------------------------------------------
# Already current
# --------------------------------------------------

if [ "$OLD_COMMIT" = "$REMOTE_COMMIT" ]; then
    echo
    echo "ALREADY UP TO DATE"
    echo "VERSION : $OLD_VERSION"

    log "UP_TO_DATE version=$OLD_VERSION commit=$OLD_COMMIT"
    exit 0
fi

# --------------------------------------------------
# Backup tag
# --------------------------------------------------

BACKUP_TAG="backup-before-update-$(date +%Y%m%d_%H%M%S)"

git tag "$BACKUP_TAG" "$OLD_COMMIT" 2>/dev/null || true

printf '%s\n' "$OLD_VERSION" \
    > "$BACKUP_DIR/version_$(date +%Y%m%d_%H%M%S).txt"

echo
echo "BACKUP TAG : $BACKUP_TAG"

# --------------------------------------------------
# Update
# --------------------------------------------------

echo
echo "===== UPDATE ====="

if ! git merge --ff-only origin/main; then
    echo "UPDATE FAILED: fast-forward unavailable"
    log "UPDATE_FAILED_FAST_FORWARD"
    exit 1
fi

NEW_COMMIT="$(git rev-parse HEAD)"
NEW_VERSION="$(cat VERSION 2>/dev/null || echo UNKNOWN)"

echo "NEW VERSION : $NEW_VERSION"
echo "NEW COMMIT  : $NEW_COMMIT"

# --------------------------------------------------
# Syntax check
# --------------------------------------------------

echo
echo "===== SYNTAX CHECK ====="

SYNTAX_FAIL=0

while IFS= read -r file; do
    [ -n "$file" ] || continue

    if bash -n "$file" >/dev/null 2>&1; then
        echo "PASS: $file"
    else
        echo "FAIL: $file"
        SYNTAX_FAIL=1
    fi
done < <(git ls-files '*.sh')

if [ "$SYNTAX_FAIL" -ne 0 ]; then

    echo
    echo "SYNTAX FAILED"
    echo "ROLLBACK -> $OLD_COMMIT"

    if git reset --hard "$OLD_COMMIT" >/dev/null 2>&1; then
        echo "ROLLBACK : PASS"
        log "ROLLBACK_SYNTAX old=$OLD_COMMIT new=$NEW_COMMIT"
    else
        echo "ROLLBACK : FAILED"
        log "ROLLBACK_FAILED_SYNTAX old=$OLD_COMMIT new=$NEW_COMMIT"
    fi

    exit 1
fi

echo "SYNTAX : PASS"

# --------------------------------------------------
# Preflight
# --------------------------------------------------

echo
echo "===== PREFLIGHT ====="

if [ -x "$ROOT/preflight.sh" ]; then

    PREFLIGHT_LOG="$TMP_DIR/preflight_update.log"

    if "$ROOT/preflight.sh" >"$PREFLIGHT_LOG" 2>&1; then
        echo "PREFLIGHT : PASS"
    else
        echo "PREFLIGHT : FAIL"

        tail -n 40 "$PREFLIGHT_LOG" 2>/dev/null || true

        echo
        echo "ROLLBACK -> $OLD_COMMIT"

        if git reset --hard "$OLD_COMMIT" >/dev/null 2>&1; then
            echo "ROLLBACK : PASS"
            log "ROLLBACK_PREFLIGHT old=$OLD_COMMIT new=$NEW_COMMIT"
        else
            echo "ROLLBACK : FAILED"
            log "ROLLBACK_FAILED_PREFLIGHT old=$OLD_COMMIT new=$NEW_COMMIT"
        fi

        exit 1
    fi

else
    echo "PREFLIGHT : SKIPPED"
fi

# --------------------------------------------------
# Final
# --------------------------------------------------

echo
echo "===== FINAL ====="

git status --short

echo
echo "VERSION : $NEW_VERSION"
echo "COMMIT  : $NEW_COMMIT"

log "UPDATE_SUCCESS version=$NEW_VERSION commit=$NEW_COMMIT"

echo
echo "=================================================="
echo " UPDATE SUCCESS"
echo "=================================================="
