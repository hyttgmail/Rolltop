#!/bin/bash
# Mutex for live menu bar tests, shared by every git worktree of this repo.
#
#   scripts/live-lock.sh acquire <name> [timeout-seconds]   wait (default 300 s) and take the lock
#   scripts/live-lock.sh release                            drop the lock
#   scripts/live-lock.sh status                             print the holder and its age
#   scripts/live-lock.sh set-pid <pid>                      record the Rolltop instance of the holder
#
# The lock is the directory tmp/live.lock/ of the MAIN checkout, holding `owner`, `pid`
# (the Rolltop instance started under the lock) and `ts` (epoch seconds of acquire).
# A lock older than 6 minutes may be taken over: the recorded Rolltop PID is stopped first.
# Hold it for at most 3 minutes (CLAUDE.md).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

LOCK="$ROLLTOP_TMP/live.lock"
STALE_AFTER=360

age() {
    local ts
    ts=$(cat "$LOCK/ts" 2>/dev/null || echo 0)
    echo $(( $(date +%s) - ts ))
}

take_over() {
    local pid
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    if rolltop_pid_is "$pid" "$ROLLTOP_BINARY"; then
        echo "live-lock: stopping stale holder's Rolltop (pid $pid)" >&2
        rolltop_stop_pid "$pid"
    fi
    rm -rf "$LOCK"
}

case "${1:-}" in
acquire)
    name=${2:?usage: live-lock.sh acquire <name> [timeout-seconds]}
    timeout=${3:-300}
    deadline=$(( $(date +%s) + timeout ))
    while true; do
        if mkdir "$LOCK" 2>/dev/null; then
            echo "$name" > "$LOCK/owner"
            : > "$LOCK/pid"
            date +%s > "$LOCK/ts"
            echo "live-lock: acquired by $name"
            exit 0
        fi
        if [[ -d "$LOCK" && $(age) -gt $STALE_AFTER ]]; then
            echo "live-lock: taking over stale lock of $(cat "$LOCK/owner" 2>/dev/null || echo '?') ($(age) s old)" >&2
            take_over
            continue
        fi
        if [[ $(date +%s) -ge $deadline ]]; then
            echo "live-lock: timed out; held by $(cat "$LOCK/owner" 2>/dev/null || echo '?') for $(age) s" >&2
            exit 1
        fi
        sleep 2
    done
    ;;
release)
    if [[ -d "$LOCK" ]]; then
        pid=$(cat "$LOCK/pid" 2>/dev/null || true)
        if rolltop_pid_is "$pid" "$ROLLTOP_BINARY"; then
            echo "live-lock: warning: Rolltop pid $pid is still running" >&2
        fi
        echo "live-lock: released (was $(cat "$LOCK/owner" 2>/dev/null || echo '?'), held $(age) s)"
        rm -rf "$LOCK"
    else
        echo "live-lock: not held"
    fi
    ;;
status)
    if [[ -d "$LOCK" ]]; then
        echo "held by $(cat "$LOCK/owner" 2>/dev/null || echo '?') for $(age) s, rolltop pid $(cat "$LOCK/pid" 2>/dev/null || true)"
    else
        echo "free"
    fi
    ;;
set-pid)
    pid=${2:?usage: live-lock.sh set-pid <pid>}
    if [[ -d "$LOCK" ]]; then echo "$pid" > "$LOCK/pid"; fi
    ;;
*)
    sed -n '2,13p' "$0"
    exit 2
    ;;
esac
