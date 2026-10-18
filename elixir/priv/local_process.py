"""Local Symphony command ownership. Linux only; no model or tracker policy.

One workspace lock covers each command. PID-namespace init is pinned with a
pidfd, checked against boot/start/UID/cwd/namespace identity, and observed dead
before the lease is released. The kernel terminates all descendants when that
namespace init exits, including descendants which change sessions.
"""
import fcntl
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import tarfile
import time
import uuid


class Unsafe(RuntimeError):
    pass


def private_dir(path):
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise Unsafe("ownership directory is not private")


def identity(pid):
    proc = Path('/proc') / str(pid)
    try:
        fields = (proc / 'stat').read_text().rsplit(') ', 1)[1].split()
        return {'pid': pid, 'start': fields[19], 'uid': proc.stat().st_uid,
                'namespace': os.readlink(proc / 'ns/pid'),
                'boot': Path('/proc/sys/kernel/random/boot_id').read_text().strip()}
    except FileNotFoundError:
        return None


def dead(fd):
    return bool(select.select([fd], [], [], 0)[0])


def stop_owned(record):
    current = identity(record['pid'])
    if current is None:
        return
    fd = os.pidfd_open(record['pid'])
    try:
        if identity(record['pid']) != record or dead(fd):
            if dead(fd):
                return
            raise Unsafe('recorded process identity changed; no signal sent')
        status = Path('/proc/%d/status' % record['pid']).read_text()
        nspid = next(line.split()[1:] for line in status.splitlines() if line.startswith('NSpid:'))
        if nspid[-1] != '1' or record['namespace'] == os.readlink('/proc/self/ns/pid'):
            raise Unsafe('target is not the owned nested namespace init')
        signal.pidfd_send_signal(fd, signal.SIGTERM)
        if not select.select([fd], [], [], 0.15)[0]:
            signal.pidfd_send_signal(fd, signal.SIGKILL)
        if not select.select([fd], [], [], 3)[0]:
            raise Unsafe('namespace termination was not confirmed')
    finally:
        os.close(fd)


def read_startup_status(fd, timeout_s=3):
    deadline = time.monotonic() + timeout_s
    data = bytearray()
    while b'\n' not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise Unsafe('namespace startup status missing or incomplete')
        chunk = os.read(fd, 4097 - len(data))
        if not chunk:
            raise Unsafe('namespace startup status incomplete')
        data.extend(chunk)
        if len(data) > 4096:
            raise Unsafe('namespace startup status exceeded bounded buffer')
    return json.loads(data.splitlines()[0])


class Lease:
    def __init__(self, workspace):
        self.workspace = str(Path(workspace).resolve())
        Path(self.workspace).parent.mkdir(parents=True, exist_ok=True)
        base = Path(self.workspace).parent / '.symphony-processes'
        private_dir(base)
        self.root = base / hashlib.sha256(self.workspace.encode()).hexdigest()
        private_dir(self.root)
        self.fd = os.open(self.root / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        st = os.fstat(self.fd)
        if st.st_uid != os.getuid() or st.st_nlink != 1 or not stat.S_ISREG(st.st_mode):
            raise Unsafe('invalid workspace lock')
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Unsafe('previous command still owns workspace; dispatch blocked') from None
        self.path = self.root / 'lease.json'
        if self.path.exists():
            if self.path.is_symlink():
                raise Unsafe('symlink lease')
            old = json.loads(self.path.read_text())
            if old['workspace'] != self.workspace:
                raise Unsafe('workspace identity mismatch')
            if old['state'] != 'stopped':
                self.event('recovery_detected', old['process'])
                stop_owned(old['process'])
                self.event('recovered_stopped', old['process'])
                old['state'] = 'stopped'
                self.write(old)

    def write(self, record):
        tmp = self.root / ('lease-' + uuid.uuid4().hex + '.tmp')
        with tmp.open('x') as f:
            json.dump(record, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def event(self, name, process=None):
        with (self.root / 'events.jsonl').open('a') as f:
            f.write(json.dumps({'event': name, 'time_ns': time.time_ns(), 'process': process}) + '\n')
            f.flush()
            os.fsync(f.fileno())

    def run(self, command):
        info_r, info_w = os.pipe()
        block_r, block_w = os.pipe()
        args = ['/usr/bin/bwrap', '--unshare-user', '--unshare-pid', '--as-pid-1',
                '--die-with-parent', '--new-session', '--cap-drop', 'ALL',
                '--bind', '/', '/', '--dev-bind', '/dev', '/dev', '--proc', '/proc',
                '--ro-bind', str(self.root.parent), str(self.root.parent),
                '--chdir', self.workspace,
                '--json-status-fd', str(info_w), '--block-fd', str(block_r),
                '--', '/bin/bash', '-lc', command]
        child = subprocess.Popen(args, cwd=self.workspace, stdin=subprocess.PIPE,
                                 pass_fds=(info_w, block_r))
        os.close(info_w)
        os.close(block_r)
        process = None
        try:
            row = read_startup_status(info_r)
            process = identity(row['child-pid'])
            if not process:
                raise Unsafe('namespace ownership unavailable')
            # Verify before releasing the startup barrier; command has not run yet.
            status = Path('/proc/%d/status' % process['pid']).read_text()
            nspid = next(line.split()[1:] for line in status.splitlines() if line.startswith('NSpid:'))
            if nspid[-1] != '1' or process['namespace'] == os.readlink('/proc/self/ns/pid'):
                raise Unsafe('PID isolation was not established')
            record = {'workspace': self.workspace, 'state': 'running',
                      'run_id': uuid.uuid4().hex, 'process': process}
            self.write(record)
            self.event('started', process)
            root_fd = os.pidfd_open(process['pid'])
            try:
                os.write(block_w, b'1')
                os.close(block_w)
                block_w = None
                input_fd = child.stdin.fileno()
                os.set_blocking(input_fd, False)
                pending = bytearray()
                while not dead(root_fd):
                    readable, writable, _ = select.select(
                        [0, root_fd], [input_fd] if pending else [], [], 0.1)
                    if 0 in readable:
                        incoming = os.read(0, 65536)
                        if not incoming:
                            stop_owned(process)
                            break
                        pending.extend(incoming)
                        if len(pending) > 8 * 1024 * 1024:
                            raise Unsafe('command input exceeded bounded buffer')
                    if input_fd in writable:
                        try:
                            count = os.write(input_fd, pending)
                            del pending[:count]
                        except BlockingIOError:
                            pass
                        except BrokenPipeError:
                            stop_owned(process)
                            break
                # An exited PID-namespace init implies every descendant is dead.
                code = child.wait(timeout=3)
                self.event('stopped_confirmed', process)
                record['state'] = 'stopped'
                self.write(record)
                return code
            finally:
                os.close(root_fd)
        finally:
            if process is not None:
                stop_owned(process)
            if block_w is not None:
                os.close(block_w)
            os.close(info_r)
            if child.poll() is None:
                child.kill()  # Only this Popen child, never a discovered/name-matched PID.
            child.wait(timeout=3)

    def snapshot(self):
        workspace = Path(self.workspace)
        if not workspace.exists():
            return
        if (workspace / '.git').exists():
            diff = subprocess.run(['/usr/bin/git', '--no-optional-locks', '-c', 'core.fsmonitor=false',
                                   '-C', self.workspace, 'diff', '--no-ext-diff', '--no-textconv',
                                   '--binary', 'HEAD'], capture_output=True, timeout=10)
            if diff.returncode != 0:
                raise Unsafe('workspace diff could not be preserved; deletion blocked')
            diff_path = self.root / ('changes-' + uuid.uuid4().hex + '.patch')
            with diff_path.open('xb') as f:
                f.write(diff.stdout)
                f.flush()
                os.fsync(f.fileno())
            if diff_path.read_bytes() != diff.stdout:
                raise Unsafe('workspace diff readback failed')
            self.event('diff_verified', {'path': str(diff_path), 'sha256': hashlib.sha256(diff.stdout).hexdigest()})
        target = self.root / ('snapshot-' + uuid.uuid4().hex + '.tar')
        files = [workspace] + sorted(workspace.rglob('*'))
        before = {}
        for p in files:
            st = p.lstat()
            if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)):
                raise Unsafe('workspace contains a special file; preservation blocked')
            if p.is_file() and not p.is_symlink():
                before[str(p.relative_to(workspace))] = hashlib.sha256(p.read_bytes()).hexdigest()
        with tarfile.open(target, 'x', dereference=False) as archive:
            archive.add(workspace, arcname='workspace', recursive=True)
        with tarfile.open(target, 'r') as archive:
            for name, digest in before.items():
                member = archive.extractfile('workspace/' + name)
                if member is None or hashlib.sha256(member.read()).hexdigest() != digest:
                    raise Unsafe('snapshot readback mismatch')
                if hashlib.sha256((workspace / name).read_bytes()).hexdigest() != digest:
                    raise Unsafe('workspace changed during preservation')
        with target.open('rb') as f:
            os.fsync(f.fileno())
        self.event('snapshot_verified', {'archive': str(target), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'files': before})


def main():
    os.umask(0o077)
    mode, workspace, *args = sys.argv[1:]
    lease = Lease(workspace)
    if mode == 'run':
        return lease.run(args[0])
    if mode == 'snapshot':
        lease.snapshot()
    elif mode != 'recover':
        raise Unsafe('unknown operation')
    return 0


_HELPER_CODES = {id(function.__code__): name for name, function in (
    ('private_dir', private_dir), ('identity', identity), ('dead', dead),
    ('stop_owned', stop_owned), ('read_startup_status', read_startup_status),
    ('Lease.__init__', Lease.__init__),
    ('Lease.write', Lease.write), ('Lease.event', Lease.event),
    ('Lease.run', Lease.run), ('Lease.snapshot', Lease.snapshot), ('main', main))}
_HELPER_CODES[id(sys._getframe().f_code)] = '<module>'


def error_diagnostic(error):
    """Only fixed labels and numeric metadata; never format exception contents."""
    kinds = (OSError, FileNotFoundError, FileExistsError, PermissionError,
             BlockingIOError, BrokenPipeError, IsADirectoryError,
             NotADirectoryError, TimeoutError, ValueError, KeyError, Unsafe,
             subprocess.TimeoutExpired, json.JSONDecodeError)
    kind = next((cls.__name__ for cls in kinds if type(error) is cls), 'unknown')
    number = OSError.errno.__get__(error) if isinstance(error, OSError) else None
    if type(number) is not int or not -(2 ** 31) <= number < 2 ** 31:
        number = None
    frames = deque(maxlen=6)
    count = 0
    trace = error.__traceback__
    while trace is not None:
        name = _HELPER_CODES.get(id(trace.tb_frame.f_code))
        frames.append({'source': 'helper' if name else 'external',
                       'function': name or 'unknown', 'line': trace.tb_lineno})
        count += 1
        trace = trace.tb_next
    return 'Symphony local process ERROR NO-GO: ' + json.dumps(
        {'type': kind, 'errno': number, 'frames': list(frames),
         'truncated': count > len(frames)}, separators=(',', ':'))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, Unsafe, subprocess.TimeoutExpired) as error:
        print(error_diagnostic(error), file=sys.stderr)
        sys.exit(73)
