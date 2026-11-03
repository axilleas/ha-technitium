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








if __name__ == '__main__':
    unittest.main()
