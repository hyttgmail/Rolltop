#!/bin/bash
# Throwaway status-item apps for live tests. Live tests conceal only these.
#
#   scripts/fixture.sh start [a|b]    build if needed, sign, install, launch, record the PID
#   scripts/fixture.sh stop  [a|b|all]  stop by the recorded PID
#   scripts/fixture.sh build          build and install both
#
#   a: /Applications/RolltopFixture.app   com.alphapengwang.rolltop-fixture   (flask icon)
#   b: /Applications/RolltopFixtureB.app  com.alphapengwang.rolltop-fixture-b  (second identity, for
#      "launch a new app while a restriction is held": a needs to be hidden to hold one)
#
# Launched by running the binary directly; PIDs live in the main checkout's tmp/.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROOT=$(rolltop_checkout_root)
SRC="$ROOT/scripts/fixture/main.swift"
BUILD="$ROOT/.build/fixture"

variant() {
    case "$1" in
    a) NAME=RolltopFixture; BUNDLE_ID=com.alphapengwang.rolltop-fixture; SYMBOL=flask ;;
    b) NAME=RolltopFixtureB; BUNDLE_ID=com.alphapengwang.rolltop-fixture-b; SYMBOL=testtube.2 ;;
    *) echo "unknown fixture $1 (a|b)" >&2; exit 2 ;;
    esac
    APP="/Applications/$NAME.app"
    BINARY="$APP/Contents/MacOS/$NAME"
    PID_FILE="$ROLLTOP_TMP/fixture-$1.pid"
}

build_one() {
    variant "$1"
    local bundle="$BUILD/$NAME.app"
    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS"
    swiftc -O -target arm64-apple-macos27.0 -o "$bundle/Contents/MacOS/$NAME" "$SRC"
    cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>RolltopFixtureSymbol</key><string>$SYMBOL</string>
</dict>
</plist>
EOF
    codesign --force --sign "$ROLLTOP_SIGN_IDENTITY" --timestamp=none "$bundle"
    rm -rf "$APP"
    ditto "$bundle" "$APP"
    echo "installed $APP"
}

running_pid() {
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if rolltop_pid_is "$pid" "$BINARY"; then echo "$pid"; fi
}

start_one() {
    variant "$1"
    if [[ ! -x "$BINARY" || "$SRC" -nt "$BINARY" ]]; then build_one "$1"; variant "$1"; fi
    local pid
    pid=$(running_pid || true)
    if [[ -n "$pid" ]]; then echo "$NAME already running (pid $pid)"; return; fi
    nohup "$BINARY" >/dev/null 2>&1 </dev/null &
    pid=$!
    disown "$pid" 2>/dev/null || true
    echo "$pid" > "$PID_FILE"
    echo "started $NAME pid $pid"
}

stop_one() {
    variant "$1"
    local pid
    pid=$(running_pid || true)
    if [[ -n "$pid" ]]; then
        rolltop_stop_pid "$pid"
        echo "stopped $NAME pid $pid"
    else
        echo "$NAME not running"
    fi
    rm -f "$PID_FILE"
}

case "${1:-}" in
start) start_one "${2:-a}" ;;
stop)
    if [[ "${2:-a}" == all ]]; then stop_one a; stop_one b; else stop_one "${2:-a}"; fi
    ;;
build) build_one a; build_one b ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
