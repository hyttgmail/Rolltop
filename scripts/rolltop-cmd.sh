#!/bin/bash
# Run a Rolltop command through its URL scheme, only if the recorded instance is alive.
#
#   scripts/rolltop-cmd.sh <command-id> [key=value ...]
#   scripts/rolltop-cmd.sh layout.set-section owner=com.alphapengwang.rolltop-fixture section=hidden
#
# Refuses when tmp/rolltop.pid does not name a running /Applications/Rolltop.app instance, so a
# URL never launches an unrecorded Rolltop through LaunchServices.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

id=${1:?usage: rolltop-cmd.sh <command-id> [key=value ...]}
shift
pid=$(rolltop_running_pid || true)
if [[ -z "$pid" ]]; then
    echo "rolltop-cmd: no recorded Rolltop instance is running; not sending $id" >&2
    exit 1
fi

query=""
for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    encoded=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$value")
    query+="${query:+&}${key}=${encoded}"
done
url="rolltop://command/${id}${query:+?$query}"
# Address the installed app explicitly: a unit-test host (same bundle id, build folder) must
# never receive it.
open -g -a "$ROLLTOP_APP" "$url"
echo "sent $url to pid $pid"
