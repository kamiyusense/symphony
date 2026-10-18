"""Exit-73 diagnostics only: stdlib, temporary owned fixtures, no command runs."""
import importlib.util
import inspect
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'priv/local_process.py'
spec = importlib.util.spec_from_file_location('diagnostic_helper', HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
PREFIX = 'Symphony local process ERROR NO-GO: '
SECRET = 'FAKE_SECRET_auth_config_token_9f2'


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=HELPER.parents[1])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / SECRET

    def diagnostic(self, error):
        line = helper.error_diagnostic(error)
        self.assertTrue(line.startswith(PREFIX))
        self.assertLessEqual(len(line.encode()) + 1, 1000)
        self.assertNotIn(SECRET, line)
        self.assertNotIn('\n', line)
        self.assertRegex(line, r'(?i)\b(error|warn|warning|failed|fatal|panic|exception)\b')
        return json.loads(line[len(PREFIX):])

    def control(self, mode='recover'):
        result = subprocess.run(
            [sys.executable, '-B', str(HELPER), mode, str(self.workspace)],
            capture_output=True, timeout=5,
            env={**os.environ, 'DIAGNOSTIC_FAKE_SECRET': SECRET})
        self.assertEqual(result.returncode, 73)
        self.assertEqual(result.stdout, b'')
        line = result.stderr.decode()
        self.assertEqual(len(line.splitlines()), 1)
        self.assertTrue(line.startswith(PREFIX))
        self.assertNotIn(SECRET, line)
        self.assertLessEqual(len(line.encode()), 1000)
        self.assertRegex(line[:1000], r'(?i)\b(error|warn|warning|failed|fatal|panic|exception)\b')
        return json.loads(line[len(PREFIX):])

    def test_private_directory_failure_exits_73_with_helper_location(self):
        base = self.root / '.symphony-processes'
        base.mkdir(mode=0o755)
        base.chmod(0o755)
        row = self.control('run')
        self.assertEqual(row['type'], 'Unsafe')
        self.assertFalse(row['truncated'])
        source, start = inspect.getsourcelines(helper.private_dir)
        expected = start + next(i for i, line in enumerate(source) if 'raise Unsafe' in line)
        self.assertEqual(row['frames'][-1],
                         {'source': 'helper', 'function': 'private_dir', 'line': expected})
        self.assertFalse(self.workspace.exists())
        self.assertEqual(list(base.iterdir()), [])

    def test_held_lock_remains_fail_closed(self):
        lease = helper.Lease(self.workspace)
        self.addCleanup(os.close, lease.fd)
        row = self.control()
        self.assertEqual(row['type'], 'Unsafe')
        self.assertEqual(row['frames'][-1]['function'], 'Lease.__init__')
        self.assertFalse(lease.path.exists())
        self.assertFalse((lease.root / 'events.jsonl').exists())

    def test_exception_payloads_and_chains_are_secret(self):
        errors = [OSError(13, SECRET, '/' + SECRET), KeyError(SECRET),
                  subprocess.TimeoutExpired([SECRET], 3, output=SECRET, stderr=SECRET)]
        for error in errors:
            with self.subTest(kind=type(error).__name__):
                try:
                    try:
                        raise ValueError(SECRET)
                    except ValueError as cause:
                        raise error from cause
                except (OSError, KeyError, subprocess.TimeoutExpired) as caught:
                    row = self.diagnostic(caught)
                self.assertEqual(row['type'], type(error).__name__)
                self.assertEqual(row['errno'], 13 if isinstance(error, OSError) else None)
                self.assertTrue(all(f['source'] == 'external' for f in row['frames']))
                self.assertTrue(all(f['function'] == 'unknown' for f in row['frames']))

    def test_deep_malicious_trace_is_bounded_and_external(self):
        # Even code claiming the helper filename must not gain trusted labels.
        namespace = {'payload': SECRET * 10000}
        exec(compile('def recurse(n):\n if n: return recurse(n-1)\n raise KeyError(payload)\n',
                     str(HELPER), 'exec'), namespace)
        try:
            namespace['recurse'](100)
        except KeyError as error:
            row = self.diagnostic(error)
        self.assertTrue(row['truncated'])
        self.assertEqual(len(row['frames']), 6)
        self.assertTrue(all(f['source'] == 'external' and f['function'] == 'unknown'
                            for f in row['frames']))

    def test_unknown_type_and_non_numeric_errno_cannot_supply_text(self):
        malicious = type(SECRET * 1000, (OSError,), {})
        error = malicious(SECRET)
        error.errno = SECRET
        row = self.diagnostic(error)
        self.assertEqual(row['type'], 'unknown')
        self.assertIsNone(row['errno'])
        error.errno = 10 ** 10000
        self.assertIsNone(self.diagnostic(error)['errno'])

    def test_real_helper_oserror_location(self):
        path = self.root / SECRET / 'absent'
        try:
            helper.private_dir(path)
        except OSError as error:
            row = self.diagnostic(error)
        source, start = inspect.getsourcelines(helper.private_dir)
        expected = start + next(i for i, line in enumerate(source) if 'path.mkdir' in line)
        self.assertEqual(row['type'], 'FileNotFoundError')
        self.assertEqual(row['errno'], 2)
        self.assertIn({'source': 'helper', 'function': 'private_dir', 'line': expected},
                      row['frames'])
        self.assertEqual(row['frames'][-1]['source'], 'external')


if __name__ == '__main__':
    unittest.main()
