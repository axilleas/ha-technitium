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
LIBRARY = ROOT / 'technitium/listeners.sh'
if LIBRARY.exists():
    FUNCTIONS += '\n' + LIBRARY.read_text()


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
ss() { [ "$1" = -Hlnpt ] && printf '%s\n' "$SOCKET"; }
SOCKET="LISTEN 0 128 0.0.0.0:53 0.0.0.0:* users:((\\"dotnet\\",pid=$$,fd=8))"
listener_owned tcp 53 $$
! listener_owned udp 53 $$
! listener_owned tcp 53 99999999
! listener_owned tcp 5380 $$
SOCKET='LISTEN 0 128 0.0.0.0:53 0.0.0.0:*'
! listener_owned tcp 53 $$
''')

    def test_listener_accepts_descendant_not_sibling_or_partial_pid(self):
        self.run_shell('''
# Both sleep processes share the executable and process group, but only one
# belongs to the supervised launcher. A process-group/name match is unsafe.
bash -c 'sleep 30 & echo $! > worker; wait' & root=$!
sleep 30 & sibling=$!
trap 'kill "$root" "$sibling" "$(cat worker)" 2>/dev/null || true' EXIT
for ((i=0; i<50; i++)); do [ ! -s worker ] || break; sleep 0.02; done
worker=$(cat worker)
ss() { printf 'LISTEN 0 128 0.0.0.0:53 0.0.0.0:* users:(("sleep",pid=%s,fd=8))\\n' "$owner"; }
owner=$worker
listener_owned tcp 53 "$root"
owner=$sibling
! listener_owned tcp 53 "$root"
owner=${root}0
! listener_owned tcp 53 "$root"
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

    def test_healthcheck_requires_udp_and_tcp_and_rejects_servfail(self):
        health = ROOT / 'technitium/healthcheck.sh'
        self.assertTrue(health.exists(), 'DNS healthcheck missing')
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'dig'
            fake.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALLS"\n'
                            'echo ";; ->>HEADER<<- opcode: QUERY, status: ${STATUS:-NOERROR}, id: 1"\n')
            fake.chmod(0o755)
            identity = Path(directory) / 'identity'
            pid = os.getpid()
            start = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[19]
            identity.write_text(f'{pid} {start}\n')
            ss = Path(directory) / 'ss'
            ss.write_text('#!/bin/bash\n'
                          '[[ "$1" != "${MISSING_PROTOCOL:-}" ]] || exit 0\n'
                          'printf \'LISTEN 0 128 0.0.0.0:53 0.0.0.0:* users:(("python",pid=%s,fd=8))\\n\' "$OWNER"\n')
            ss.chmod(0o755)
            env = {**os.environ, 'PATH': directory + ':' + os.environ['PATH'],
                   'CALLS': directory + '/calls', 'OWNER': str(pid),
                   'TECHNITIUM_IDENTITY_FILE': str(identity)}
            self.assertEqual(subprocess.run(['bash', str(health)], env=env).returncode, 0)
            calls = Path(env['CALLS']).read_text()
            self.assertIn('+tcp', calls)
            self.assertIn('+notcp', calls)
            self.assertIn('+ignore', calls)  # UDP truncation must not fall back to TCP.
            self.assertNotEqual(subprocess.run(['bash', str(health)], env={**env, 'STATUS': 'SERVFAIL'}).returncode, 0)
            for missing in ('-Hlnpt', '-Hlnpu'):
                self.assertNotEqual(subprocess.run(['bash', str(health)], env={**env, 'MISSING_PROTOCOL': missing}).returncode, 0)
            for owner in ('99999999', str(pid) + '0'):
                self.assertNotEqual(subprocess.run(['bash', str(health)], env={**env, 'OWNER': owner}).returncode, 0)
            for stale in (f'{pid} 0\n', '99999999 1\n', 'bad data\n', f'{pid} {start} extra\n'):
                identity.write_text(stale)
                self.assertNotEqual(subprocess.run(['bash', str(health)], env=env).returncode, 0)
            identity.unlink()
            self.assertNotEqual(subprocess.run(['bash', str(health)], env=env).returncode, 0)


if __name__ == '__main__':
    unittest.main()
