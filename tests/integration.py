"""Build first; run with python3 tests/integration.py [bridge|none].
Only the uniquely named test container is touched. No published ports or host data.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

IMAGE = 'ha-technitium-hardening-test:1.0.7'
NAME = 'technitium-test-' + uuid.uuid4().hex[:12]
NETWORK = sys.argv[1] if len(sys.argv) > 1 else 'bridge'
assert NETWORK in ('bridge', 'none')


def docker(*args, check=True):
    return subprocess.run(['docker', *args], text=True, capture_output=True, check=check)


def execute(command, check=True):
    return docker('exec', NAME, 'bash', '-ec', command, check=check)


def eventually(command, seconds=90):
    deadline = time.monotonic() + seconds
    last_error = ''
    while time.monotonic() < deadline:
        result = execute(command, check=False)
        last_error = result.stderr
        if result.returncode == 0:
            return result.stdout
        time.sleep(1)
    raise AssertionError(f'Timed out: {command}: {last_error}')


with tempfile.TemporaryDirectory(prefix='technitium-test-', dir=os.environ.get('TMPDIR')) as directory:
    try:
        docker('run', '-d', '--init', '--name', NAME, '--network', NETWORK,
               '--tmpfs', '/config:rw', IMAGE)
        eventually('test -f /tmp/nginx.pid && /healthcheck.sh')
        state = json.loads(docker('inspect', NAME).stdout)[0]
        assert state['HostConfig']['NetworkMode'] == NETWORK
        assert not state['HostConfig']['PortBindings']
        print('PASS isolated startup and UDP/TCP healthcheck', flush=True)
        for transport in ('+notcp', '+tcp'):
            response = execute(f'dig @127.0.0.1 localhost. A +norecurse {transport} +time=2 +tries=1').stdout
            assert any('status: ' + status in response for status in ('NOERROR', 'NXDOMAIN', 'REFUSED')), response
            assert 'SERVER: 127.0.0.1#53' in response
        print('PASS real UDP and TCP DNS responses (including valid policy refusal)', flush=True)
        response = execute("exec 3<>/dev/tcp/127.0.0.1/5380; printf 'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3; cat <&3").stdout
        assert '200 OK' in response
        print('PASS native Web UI HTTP 200', flush=True)
        # Permit loopback ONLY in this isolated test container to exercise proxying.
        execute('c=$(cat /tmp/technitium-ingress-nginx.conf); '
                'printf "%s\\n" "${c/allow 172.30.32.2;/allow 127.0.0.1;}" > /tmp/technitium-ingress-nginx.conf; '
                'kill -HUP "$(cat /tmp/nginx.pid)"')
        time.sleep(1)
        token = 'TEST_ONLY_QUERY_TOKEN_7af139'
        response = execute("exec 3<>/dev/tcp/127.0.0.1/8099; printf 'GET /?token=" + token + " HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3; cat <&3").stdout
        assert '200 OK' in response
        dns_pid = execute('pgrep -x dotnet').stdout.strip()
        old_proxy = execute('cat /tmp/nginx.pid').stdout.strip()
        execute('kill -TERM "$(cat /tmp/nginx.pid)"')
        for _ in range(5):
            execute('/healthcheck.sh')
            time.sleep(0.5)
        new_proxy = eventually(f'test "$(cat /tmp/nginx.pid)" != "{old_proxy}" && kill -0 "$(cat /tmp/nginx.pid)"', 15)
        assert execute('pgrep -x dotnet').stdout.strip() == dns_pid
        print('PASS proxy restarts while same DNS process keeps answering', flush=True)
        assert token not in docker('logs', NAME).stdout + docker('logs', NAME).stderr
        print('PASS query token absent from container logs', flush=True)
        eventually('/healthcheck.sh')
        docker('stop', '-t', '12', NAME)
        state = json.loads(docker('inspect', NAME).stdout)[0]['State']
        assert not state['Running'] and state['ExitCode'] == 0, state
        print('PASS graceful stop with exit 0', flush=True)
        docker('start', NAME)
        eventually('test -f /tmp/nginx.pid && /healthcheck.sh')
        execute('kill -STOP "$(pgrep -x dotnet)"')
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            state = json.loads(docker('inspect', NAME).stdout)[0]['State']
            if not state['Running']:
                break
            time.sleep(2)
        assert not state['Running'] and state['ExitCode'] == 1, state
        logs = docker('logs', NAME).stdout
        assert 'DNS is unhealthy' in logs
        print('PASS hung DNS is detected despite live PID and exits nonzero', flush=True)
    except Exception:
        print(docker('logs', NAME, check=False).stdout)
        print(docker('logs', NAME, check=False).stderr)
        raise
    finally:
        docker('rm', '-f', NAME, check=False)
