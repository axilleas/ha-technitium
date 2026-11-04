#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=technitium/listeners.sh
source "$(dirname "${BASH_SOURCE[0]}")/listeners.sh"
identity_file="${TECHNITIUM_IDENTITY_FILE:-/run/technitium.identity}"
# No process-name/group guessing: only the launch recorded by the wrapper is
# trusted. Missing, malformed and stale identity files fail closed.
[ -r "$identity_file" ] || exit 1
identity=$(< "$identity_file")
[[ "$identity" =~ ^([1-9][0-9]*)\ ([0-9]+)$ ]] || exit 1
pid=${BASH_REMATCH[1]}
start=${BASH_REMATCH[2]}
listener_owned tcp 53 "$pid" "$start" || exit 1
listener_owned udp 53 "$pid" "$start" || exit 1
# Nonrecursive local queries need no Internet. REFUSED is a valid DNS policy
# response; SERVFAIL and malformed/time-out replies fail.
for transport in +notcp +tcp; do
  reply=$(dig @127.0.0.1 -p 53 localhost. A +norecurse "$transport" +ignore +time=2 +tries=1 +comments +noanswer)
  grep -Eq 'status: (NOERROR|NXDOMAIN|REFUSED),' <<< "$reply" || exit 1
done
