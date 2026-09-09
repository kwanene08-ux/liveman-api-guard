#!/data/data/com.termux/files/usr/bin/bash
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1

STATE_DIR="$ROOT/state"
BACKUP_DIR="$ROOT/backup"
LOG_DIR="$ROOT/logs"

mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$LOG_DIR"

log() {
    printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_DIR/rollback.log" 2>/dev/null || true
}

fail() {
    echo "ROLLBACK FAILED: $1"
    log "FAIL $1"
    exit 1
}

get_version_at_commit() {
    local commit="$1"
    local version
    version="$(git show "${commit}:VERSION" 2>/dev/null || true)"
    [ -n "$version" ] && printf '%s\n' "$version" || printf '%s\n' "MISSING"
}

echo "=================================================="
echo " LIVE MAN API GUARD SAFE ROLLBACK"
echo "=================================================="

command -v git >/dev/null 2>&1 || fail "git missing"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not git repo"

if [ -f "$STATE_DIR/rider.pid" ]; then
    PID="$(tr -cd '0-9' < "$STATE_DIR/rider.pid" 2>/dev/null || true)"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        fail "rider.sh is running PID=$PID; stop it first"
    fi
fi

CURRENT="$(git rev-parse HEAD 2>/dev/null || true)"
[ -n "$CURRENT" ] || fail "current commit unavailable"

CURRENT_VERSION="$(get_version_at_commit "$CURRENT")"

echo "CURRENT COMMIT  : $CURRENT"
echo "CURRENT VERSION : $CURRENT_VERSION"

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    TARGET="$(git tag --list 'backup-before-update-*' --sort=-creatordate | head -n 1)"
fi

[ -n "$TARGET" ] || TARGET="HEAD~1"

git rev-parse "$TARGET" >/dev/null 2>&1 || fail "target not found: $TARGET"

TARGET_COMMIT="$(git rev-parse "$TARGET")"
TARGET_VERSION="$(get_version_at_commit "$TARGET_COMMIT")"

if [ "$TARGET_COMMIT" = "$CURRENT" ]; then
    echo "ALREADY AT TARGET: $CURRENT"
    exit 0
fi

echo "TARGET           : $TARGET"
echo "TARGET COMMIT    : $TARGET_COMMIT"
echo "TARGET VERSION   : $TARGET_VERSION"

RECOVERY_TAG="recovery-before-rollback-$(date +%Y%m%d_%H%M%S)"
git tag "$RECOVERY_TAG" "$CURRENT" 2>/dev/null || fail "cannot create recovery tag"

echo "RECOVERY TAG     : $RECOVERY_TAG"
echo
echo "===== ROLLBACK ====="

git reset --hard "$TARGET_COMMIT" >/dev/null 2>&1 || fail "git reset failed"
echo "RESET             : PASS"

SYNTAX_FAIL=0
while IFS= read -r FILE; do
    [ -n "$FILE" ] || continue
    if ! bash -n "$FILE" >/dev/null 2>&1; then
        echo "SYNTAX FAIL       : $FILE"
        SYNTAX_FAIL=1
    fi
done < <(git ls-files '*.sh')

if [ "$SYNTAX_FAIL" -ne 0 ]; then
    echo "ROLLBACK CHECK    : FAILED"
    echo "RESTORING         : $RECOVERY_TAG"
    if git reset --hard "$CURRENT" >/dev/null 2>&1; then
        echo "RESTORE            : PASS"
        log "ROLLBACK_REJECTED target=$TARGET_COMMIT restored=$CURRENT"
    else
        echo "RESTORE            : FAILED"
        log "ROLLBACK_AND_RESTORE_FAILED target=$TARGET_COMMIT recovery=$CURRENT"
    fi
    exit 1
fi

NEW_COMMIT="$(git rev-parse HEAD)"
NEW_VERSION="$(get_version_at_commit "$NEW_COMMIT")"

cat > "$STATE_DIR/rollback.state" <<STATE
STATUS=ROLLED_BACK
FROM=$CURRENT
TO=$NEW_COMMIT
VERSION=$NEW_VERSION
TIME=$(date '+%Y-%m-%d %H:%M:%S')
RECOVERY_TAG=$RECOVERY_TAG
STATE_OWNER=rollback.sh
STATE

echo "SYNTAX CHECK       : PASS"
echo "NEW COMMIT         : $NEW_COMMIT"
echo "NEW VERSION        : $NEW_VERSION"

log "ROLLBACK_SUCCESS from=$CURRENT to=$NEW_COMMIT version=$NEW_VERSION"

echo "=================================================="
echo " ROLLBACK SUCCESS"
echo "=================================================="
