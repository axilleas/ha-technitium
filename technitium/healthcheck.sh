#!/usr/bin/env bash
set -euo pipefail
# Nonrecursive local queries need no Internet. REFUSED is a valid DNS policy
# response; SERVFAIL and malformed/time-out replies fail.
for transport in +notcp +tcp; do
  reply=$(dig @127.0.0.1 -p 53 localhost. A +norecurse "$transport" +ignore +time=2 +tries=1 +comments +noanswer)
  grep -Eq 'status: (NOERROR|NXDOMAIN|REFUSED),' <<< "$reply" || exit 1
done
