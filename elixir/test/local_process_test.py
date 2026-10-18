"""Real Linux process tests: no Codex binary, credentials, or network required."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'priv/local_process.py'
spec = importlib.util.spec_from_file_location('owned', HELPER)
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
ROOT = Path(tempfile.mkdtemp(prefix='symphony-owned-', dir=os.environ.get('SYMPHONY_PROCESS_TEST_ROOT')))


def wait(predicate):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError('observable process condition not reached')


def members(namespace):
    found = []
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            if os.readlink(path / 'ns/pid') == namespace:
                state = (path / 'stat').read_text().rsplit(') ', 1)[1].split()[0]
                if state != 'Z':
                    found.append(int(path.name))
        except FileNotFoundError:
            pass
    return found


class OwnedProcessTests(unittest.TestCase):
    def setUp(self):
        self.ws = ROOT / self._testMethodName
        self.ws.mkdir(mode=0o700)
        self.handles = []
        self.fds = []
        self.sentinel = subprocess.Popen(['/usr/bin/sleep', '60'])
        self.handles.append(self.sentinel)
        script = self.ws / 'work.py'
        script.write_text("import subprocess,time,pathlib\nsubprocess.Popen(['/usr/bin/sleep','60'],start_new_session=True)\npathlib.Path('ready').write_text('ready')\ntime.sleep(60)\n")
        self.command = '/usr/bin/python3 -B ' + shlex.quote(str(script))

    def tearDown(self):
        self.assertIsNone(self.sentinel.poll(), 'unrelated sentinel was stopped')
        self.sentinel.terminate()
        for handle in self.handles:
            if handle.stdin and not handle.stdin.closed:
                handle.stdin.close()
            if handle.poll() is None:
                try:
                    handle.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    handle.kill()  # Only an exact Popen handle created by this test.
                    handle.wait(timeout=4)
            if handle.stdout:
                output = handle.stdout.read()
                with (self.ws / ('process-%d.log' % handle.pid)).open('xb') as f:
                    f.write(output)
                handle.stdout.close()
        for fd in self.fds:
            os.close(fd)

    def control_path(self):
        return self.ws.parent / '.symphony-processes' / owned.hashlib.sha256(str(self.ws).encode()).hexdigest()

    def record(self):
        path = self.control_path() / 'lease.json'
        return json.loads(path.read_text()) if path.exists() else None

    def start(self, command=None):
        p = subprocess.Popen([sys.executable, '-B', str(HELPER), 'run', str(self.ws), command or self.command], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.handles.append(p)
        record = wait(lambda: self.record())
        wait(lambda: (self.ws / 'ready').exists() or p.poll() is not None)
        self.assertIsNone(p.poll(), p.stdout.read() if p.poll() is not None else '')
        return p, record

    def control(self, mode):
        return subprocess.run([sys.executable, '-B', str(HELPER), mode, str(self.ws)], capture_output=True, timeout=6)

    def test_A_normal_exit_kills_detached_descendant(self):
        script = self.ws / 'normal.py'
        script.write_text("import subprocess,time,pathlib\nsubprocess.Popen(['/usr/bin/sleep','60'],start_new_session=True)\npathlib.Path('ready').write_text('ready')\ntime.sleep(0.5)\n")
        p, record = self.start('/usr/bin/python3 -B ' + shlex.quote(str(script)))
        self.assertGreaterEqual(len(members(record['process']['namespace'])), 2)
        self.assertEqual(p.wait(timeout=4), 0)
        self.assertEqual(members(record['process']['namespace']), [])
        self.assertEqual(self.record()['state'], 'stopped')

    def test_B_stop_request_confirms_all_descendants_gone(self):
        p, record = self.start()
        self.assertGreaterEqual(len(members(record['process']['namespace'])), 2)
        p.stdin.close()
        p.wait(timeout=4)
        self.assertEqual(members(record['process']['namespace']), [])
        self.assertEqual(self.record()['state'], 'stopped')

    def test_B_stop_is_not_blocked_by_full_child_stdin(self):
        p, record = self.start()
        os.set_blocking(p.stdin.fileno(), False)
        for _ in range(100):
            try:
                os.write(p.stdin.fileno(), b'x' * 65536)
            except BlockingIOError:
                time.sleep(0.01)
        p.stdin.close()
        p.wait(timeout=3)
        self.assertEqual(members(record['process']['namespace']), [])

    def test_C_crashed_guard_is_detected_before_recovery(self):
        p, record = self.start()
        p.kill()
        p.wait(timeout=4)
        self.assertEqual(self.record()['state'], 'running')
        result = self.control('recover')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(members(record['process']['namespace']), [])
        self.assertIn('recovery_detected', (self.control_path() / 'events.jsonl').read_text())

    def test_C_real_owner_VM_crash_closes_port_and_reaps_namespace(self):
        bridge = HELPER.parents[1] / 'lib/symphony_elixir/local_process.ex'
        code = 'Code.require_file(' + json.dumps(str(bridge)) + '); {:ok,_}=SymphonyElixir.LocalProcess.open(' + json.dumps(str(self.ws)) + ',' + json.dumps(self.command) + '); Process.sleep(:infinity)'
        vm = subprocess.Popen(['elixir', '-e', code], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.handles.append(vm)
        record = wait(lambda: self.record())
        wait(lambda: (self.ws / 'ready').exists())
        self.assertTrue(members(record['process']['namespace']))
        vm.kill()
        vm.wait(timeout=4)
        wait(lambda: not members(record['process']['namespace']))
        self.assertEqual(self.control('recover').returncode, 0)
        self.assertEqual(members(record['process']['namespace']), [])

    def test_D_unknown_identity_blocks_command_and_preserves_foreign_process(self):
        lease = owned.Lease(str(self.ws))
        foreign = owned.identity(self.sentinel.pid)
        foreign['start'] = 'not-the-observed-start'
        lease.write({'workspace': str(self.ws), 'state': 'running', 'process': foreign})
        os.close(lease.fd)
        command = '/usr/bin/touch ' + shlex.quote(str(self.ws / 'MUST_NOT_START'))
        p = subprocess.run([sys.executable, '-B', str(HELPER), 'run', str(self.ws), command], stdin=subprocess.PIPE, capture_output=True, timeout=4)
        self.assertEqual(p.returncode, 73)
        self.assertFalse((self.ws / 'MUST_NOT_START').exists())
        self.assertIsNone(self.sentinel.poll())

    def test_E_recover_identified_legacy_orphan_namespace(self):
        lease = owned.Lease(str(self.ws))
        fd_r, fd_w = os.pipe()
        legacy = subprocess.Popen(['/usr/bin/bwrap', '--unshare-user', '--unshare-pid', '--as-pid-1', '--new-session', '--bind', '/', '/', '--proc', '/proc', '--json-status-fd', str(fd_w), '--', '/usr/bin/sleep', '60'], pass_fds=(fd_w,))
        self.handles.append(legacy)
        os.close(fd_w)
        row = json.loads(os.read(fd_r, 4096).splitlines()[0])
        os.close(fd_r)
        record = owned.identity(row['child-pid'])
        self.assertTrue(members(record['namespace']))
        lease.write({'workspace': str(self.ws), 'state': 'running', 'process': record})
        os.close(lease.fd)
        result = self.control('recover')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(members(record['namespace']), [])
        self.assertIsNotNone(legacy.wait(timeout=4))
        self.assertIn('recovered_stopped', (self.control_path() / 'events.jsonl').read_text())

    def test_F_same_namespace_is_never_a_signal_target(self):
        lease = owned.Lease(str(self.ws))
        lease.write({'workspace': str(self.ws), 'state': 'running', 'process': owned.identity(self.sentinel.pid)})
        os.close(lease.fd)
        result = self.control('recover')
        self.assertEqual(result.returncode, 73)
        self.assertIsNone(self.sentinel.poll())

    def test_G_duplicate_command_is_blocked_by_live_owner(self):
        p, record = self.start()
        second = subprocess.run([sys.executable, '-B', str(HELPER), 'run', str(self.ws), 'touch DUPLICATE'], stdin=subprocess.PIPE, capture_output=True, timeout=4)
        self.assertEqual(second.returncode, 73)
        self.assertFalse((self.ws / 'DUPLICATE').exists())
        p.stdin.close()
        p.wait(timeout=4)
        self.assertEqual(members(record['process']['namespace']), [])

    def test_H_new_mock_work_after_confirmed_stop(self):
        p, record = self.start()
        p.stdin.close()
        p.wait(timeout=4)
        self.assertEqual(members(record['process']['namespace']), [])
        p2 = subprocess.Popen([sys.executable, '-B', str(HELPER), 'run', str(self.ws), 'printf new > next-result'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.handles.append(p2)
        self.assertEqual(p2.wait(timeout=4), 0)
        self.assertEqual((self.ws / 'next-result').read_text(), 'new')

    def test_G_command_cannot_overwrite_ownership_record(self):
        lease = owned.Lease(str(self.ws))
        path = lease.path
        os.close(lease.fd)
        code = "from pathlib import Path;Path(" + repr(str(path)) + ").write_text('tampered')"
        p = subprocess.Popen([sys.executable, '-B', str(HELPER), 'run', str(self.ws), '/usr/bin/python3 -c ' + shlex.quote(code)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.handles.append(p)
        self.assertNotEqual(p.wait(timeout=4), 0)
        self.assertEqual(self.record()['state'], 'stopped')
        self.assertNotEqual(path.read_text(), 'tampered')

    def test_K_fragmented_startup_status_is_read_before_releasing_command(self):
        wrapper = self.ws / 'fragmented.py'
        wrapper.write_text("import importlib.util,os,sys\n"
                           "s=importlib.util.spec_from_file_location('owned', " + repr(str(HELPER)) + ");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                           "original=os.read\ndef fragmented(fd,size):\n    return original(fd,1 if fd!=0 and size<=8192 else size)\n"
                           "os.read=fragmented\nsys.exit(m.main())\n")
        p = subprocess.Popen([sys.executable, '-B', str(wrapper), 'run', str(self.ws), 'printf ready > ready'],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.handles.append(p)
        self.assertEqual(p.wait(timeout=4), 0, p.stdout.read() if p.poll() else '')
        self.assertEqual((self.ws / 'ready').read_text(), 'ready')
        self.assertEqual(self.record()['state'], 'stopped')
        self.assertEqual(members(self.record()['process']['namespace']), [])

    def test_K_incomplete_startup_status_is_rejected(self):
        read_fd, write_fd = os.pipe()
        self.fds.append(read_fd)
        os.write(write_fd, b'{"child-pid":')
        os.close(write_fd)
        with self.assertRaises(owned.Unsafe):
            owned.read_startup_status(read_fd)

    def test_K_oversized_startup_status_is_rejected(self):
        read_fd, write_fd = os.pipe()
        self.fds.extend([read_fd, write_fd])
        os.write(write_fd, b'x' * 4097)
        with self.assertRaises(owned.Unsafe):
            owned.read_startup_status(read_fd)

    def test_K_silent_startup_status_times_out(self):
        read_fd, write_fd = os.pipe()
        self.fds.extend([read_fd, write_fd])
        with self.assertRaises(owned.Unsafe):
            owned.read_startup_status(read_fd, timeout_s=0.02)

    def test_K_malformed_startup_status_is_rejected(self):
        read_fd, write_fd = os.pipe()
        self.fds.extend([read_fd, write_fd])
        os.write(write_fd, b'not-json\n')
        with self.assertRaises(json.JSONDecodeError):
            owned.read_startup_status(read_fd)

    def test_J_snapshot_has_verified_bytes_before_delete(self):
        (self.ws / 'result.txt').write_text('durable result')
        result = self.control('snapshot')
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = list(self.control_path().glob('snapshot-*.tar'))
        self.assertEqual(len(archives), 1)
        with tarfile.open(archives[0]) as archive:
            self.assertEqual(archive.extractfile('workspace/result.txt').read(), b'durable result')
        self.assertIn('snapshot_verified', (self.control_path() / 'events.jsonl').read_text())
        self.assertTrue(self.ws.exists())

    def test_J_git_diff_is_preserved_and_read_back(self):
        def git(*args):
            return subprocess.run(['/usr/bin/git', '-C', str(self.ws), *args], capture_output=True, check=True)
        git('init', '-b', 'fixture')
        (self.ws / 'result.txt').write_text('before')
        git('add', 'result.txt')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@local.invalid', 'commit', '-m', 'fixture')
        (self.ws / 'result.txt').write_text('after')
        result = self.control('snapshot')
        self.assertEqual(result.returncode, 0, result.stderr)
        patches = list(self.control_path().glob('changes-*.patch'))
        self.assertEqual(len(patches), 1)
        self.assertIn(b'-before', patches[0].read_bytes())
        self.assertIn(b'+after', patches[0].read_bytes())
        events = (self.control_path() / 'events.jsonl').read_text()
        self.assertLess(events.index('diff_verified'), events.index('snapshot_verified'))

    def test_J_special_file_preservation_failure_is_not_success(self):
        os.mkfifo(self.ws / 'unpreservable-fifo')
        result = self.control('snapshot')
        self.assertEqual(result.returncode, 73)
        self.assertTrue((self.ws / 'unpreservable-fifo').exists())


if __name__ == '__main__':
    print('Retained process evidence: ' + str(ROOT), flush=True)
    unittest.main(verbosity=2)
