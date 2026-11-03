"""Isolated regression tests; never source the original startup script."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'technitium/run.sh').read_text()
# Extract definitions only, deliberately excluding all top-level startup code.
# NGINX heredoc contains unindented braces; mask those during extraction.
start = SOURCE.index('  cat >"${NGINX_CONFIG}" <<NGINX')
end = SOURCE.index('\nNGINX', start)
masked = SOURCE[:start] + SOURCE[start:end].replace('\n}', '\n    }') + SOURCE[end:]
FUNCTIONS = '\n'.join(re.findall(r'^\w+\(\) \{\n.*?^\}', masked, re.M | re.S))


class RuntimeTests(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', '-c', 'set -e\n' + FUNCTIONS + '\n' + body],
                                    cwd=directory, text=True, capture_output=True,
                                    timeout=12, env={**os.environ, 'TMPDIR': directory})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_proxy_does_not_log_query_tokens(self):
        self.run_shell('NGINX_CONFIG=config; TECHNITIUM_WEB_PORT=5380; INGRESS_PROXY_PORT=8099; '
                       'write_nginx_config; grep -q "access_log off;" config; '
                       'grep -q "error_log /dev/null" config')

    def test_owned_listener_checks_protocol_port_and_pid(self):
        self.run_shell('''
ss() { printf '%s\n' "$SOCKET"; }
SOCKET='LISTEN 0 128 0.0.0.0:53 0.0.0.0:* users:(("dotnet",pid=123,fd=8))'
listener_owned tcp 53 123
! listener_owned udp 53 999
! listener_owned tcp 53 12
! listener_owned tcp 5380 123
SOCKET='LISTEN 0 128 0.0.0.0:53 0.0.0.0:*'
! listener_owned tcp 53 123
''')

    def test_startup_timeout_fails_and_dead_process_fails(self):
        self.run_shell('''
log() { :; }; sleep() { :; }; listener_owned() { return 1; }
! wait_for_port tcp 53 dns $$ 1
! wait_for_port tcp 53 dns 99999999 1
''')

    def test_proxy_restart_is_backed_off_and_dns_survives(self):
        self.run_shell('''
log() { :; }; NGINX_PID=''; NGINX_RETRY_AT=0; NGINX_BACKOFF=1
SECONDS=0; starts=0
start_nginx() { starts=$((starts + 1)); NGINX_PID=''; return 1; }
maintain_nginx; test "$starts" = 1
maintain_nginx; test "$starts" = 1
SECONDS=2; maintain_nginx; test "$starts" = 2
SECONDS=100; maintain_nginx; test "$starts" = 3
test "$NGINX_BACKOFF" -le 60
''')

    def test_shutdown_reaps_both_children(self):
        self.run_shell('''
log() { :; }; SHUTDOWN_TIMEOUT=1
sleep 30 & TECHNITIUM_PID=$!
sleep 30 & NGINX_PID=$!
sleep 30 & SLEEP_PID=$!
trap 'kill "$SLEEP_PID" 2>/dev/null || true' EXIT
shutdown
! kill -0 "$TECHNITIUM_PID" 2>/dev/null
! kill -0 "$NGINX_PID" 2>/dev/null
! kill -0 "$SLEEP_PID" 2>/dev/null
''')

    def test_shutdown_kills_uncooperative_child_within_deadline(self):
        self.run_shell('''
log() { :; }; SHUTDOWN_TIMEOUT=1
bash -c 'trap "" TERM; while :; do :; done' & TECHNITIUM_PID=$!
NGINX_PID=''
sleep 0.1
shutdown
! kill -0 "$TECHNITIUM_PID" 2>/dev/null
''')



if __name__ == '__main__':
    unittest.main()
