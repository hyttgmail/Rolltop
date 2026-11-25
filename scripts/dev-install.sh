#!/bin/bash
# Build, sign, install to /Applications/Rolltop.app and launch.
#
#   scripts/dev-install.sh [--shell | --open | --no-launch] [--release] [--no-build]
#
#   --shell      (default) run the binary directly: it inherits the terminal's
#                Accessibility/Screen Recording grants; stderr/stdout go to tmp/rolltop-shell.log
#                with ROLLTOP_LOG_STDERR=1. Results are "shell launch only".
#   --open       launch through LaunchServices (`open`): the app's own TCC grants apply.
#   --no-launch  build and install only.
#   --no-build   relaunch the copy already in /Applications (use inside the live lock).
#
# The previous instance is stopped by the PID recorded in tmp/rolltop.pid (main checkout),
# never by name. The new PID is recorded there and in the live lock when it is held.
# Take the live lock first: scripts/live-lock.sh acquire <name>.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

mode=--shell
configuration=Debug
build=1
for arg in "$@"; do
    case "$arg" in
    --shell | --open | --no-launch) mode=$arg ;;
    --release) configuration=Release ;;
    --no-build) build=0 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

ROOT=$(rolltop_checkout_root)
cd "$ROOT"
DD="$ROOT/.build/dd"
PRODUCT="$DD/Build/Products/$configuration/Rolltop.app"

if [[ $build == 1 ]]; then
    xcodegen generate --quiet
    xcodebuild -project Rolltop.xcodeproj -scheme Rolltop -configuration "$configuration" -destination "platform=macOS,arch=arm64" -derivedDataPath "$DD" build -quiet
    # Keep LaunchServices from routing rolltop:// to the build-folder copy.
    "$LSREGISTER" -u "$PRODUCT" >/dev/null 2>&1 || true
    codesign --force --sign "$ROLLTOP_SIGN_IDENTITY" --entitlements Rolltop/Resources/Rolltop.entitlements \
        --timestamp=none "$PRODUCT"
fi

if pid=$(rolltop_running_pid) && [[ -n "$pid" ]]; then
    echo "stopping previous Rolltop (pid $pid)"
    rolltop_stop_pid "$pid"
fi
rm -f "$ROLLTOP_PID_FILE"

if [[ $build == 1 ]]; then
    rm -rf "$ROLLTOP_APP"
    ditto "$PRODUCT" "$ROLLTOP_APP"
    codesign --verify --strict "$ROLLTOP_APP"
    "$LSREGISTER" -f "$ROLLTOP_APP" >/dev/null 2>&1 || true
    echo "installed $ROLLTOP_APP ($configuration)"
fi

case "$mode" in
--no-launch)
    exit 0
    ;;
--shell)
    log="$ROLLTOP_TMP/rolltop-shell.log"
    ROLLTOP_LOG_STDERR=1 nohup "$ROLLTOP_BINARY" >>"$log" 2>&1 </dev/null &
    pid=$!
    disown "$pid" 2>/dev/null || true
    ;;
--open)
    open -g "$ROLLTOP_APP"
    pid=""
    for _ in $(seq 1 50); do
        # No early exit in awk: a closed pipe would kill this script under pipefail.
        pid=$(ps -axo pid=,command= | awk -v bin="$ROLLTOP_BINARY" '$2 == bin { print $1 }' | tail -n 1 || true)
        [[ -n "$pid" ]] && break
        sleep 0.1
    done
    [[ -n "$pid" ]] || { echo "Rolltop did not start (or its pid was not found); check: ps -axo pid,command | grep MacOS/Rolltop" >&2; exit 1; }
    ;;
esac

sleep 0.5
if ! rolltop_pid_is "$pid" "$ROLLTOP_BINARY"; then
    echo "Rolltop (pid $pid) exited right after launch; see $ROLLTOP_TMP/rolltop-shell.log" >&2
    exit 1
fi
echo "$pid" > "$ROLLTOP_PID_FILE"
"$(dirname "$0")/live-lock.sh" set-pid "$pid"
echo "launched Rolltop pid $pid ($mode)"
