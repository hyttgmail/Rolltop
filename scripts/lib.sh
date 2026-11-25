# Shared helpers for scripts/*.sh. Source it; do not run it.

# Main checkout root, also from a linked worktree (resolved through the common git dir).
rolltop_main_root() {
    local common
    common=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --path-format=absolute --git-common-dir)
    dirname "$common"
}

# This checkout (worktree) root.
rolltop_checkout_root() {
    git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel
}

ROLLTOP_MAIN_ROOT=$(rolltop_main_root)
ROLLTOP_TMP="$ROLLTOP_MAIN_ROOT/tmp"
ROLLTOP_PID_FILE="$ROLLTOP_TMP/rolltop.pid"
ROLLTOP_APP=/Applications/Rolltop.app
ROLLTOP_BINARY="$ROLLTOP_APP/Contents/MacOS/Rolltop"
# Signing identity: the environment variable, else the one line of .signing-identity in the
# main checkout (not in git), else ad-hoc ("-"; macOS then asks for permissions after each build).
if [[ -z "${ROLLTOP_SIGN_IDENTITY:-}" && -s "$ROLLTOP_MAIN_ROOT/.signing-identity" ]]; then
    ROLLTOP_SIGN_IDENTITY=$(head -n 1 "$ROLLTOP_MAIN_ROOT/.signing-identity")
fi
ROLLTOP_SIGN_IDENTITY=${ROLLTOP_SIGN_IDENTITY:--}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$ROLLTOP_TMP"

# True when $1 is a live process whose executable is $2.
rolltop_pid_is() {
    local pid=$1 binary=$2 command
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
    command=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
    [[ "$command" == "$binary"* ]]
}

# PID of the Rolltop instance recorded by dev-install, if it is still that instance.
rolltop_running_pid() {
    local pid
    pid=$(cat "$ROLLTOP_PID_FILE" 2>/dev/null || true)
    if rolltop_pid_is "$pid" "$ROLLTOP_BINARY"; then echo "$pid"; fi
}

# Stops a process by PID (TERM, then KILL after ~3 s). Never by name.
rolltop_stop_pid() {
    local pid=$1 i
    kill -TERM "$pid" 2>/dev/null || return 0
    for i in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
}
