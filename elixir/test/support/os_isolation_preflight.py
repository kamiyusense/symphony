import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


def report(name, **fields):
    print(json.dumps(dict(check=name, **fields)), flush=True)


def read_state(name, path, fields=None):
    try:
        value = Path(path).read_text()[:4096].strip()
        if fields:
            value = [line for line in value.splitlines() if line.split(":", 1)[0] in fields]
        report(name, result="PASS", value=value)
    except OSError as exc:
        report(name, result="UNKNOWN", error=type(exc).__name__, errno=exc.errno)


def probe(name, command):
    timer = shutil.which("timeout")
    if not timer or not command[0]:
        report(name, result="UNKNOWN", exit_code=None, stderr="required executable absent")
        return False
    result = subprocess.run(
        [timer, "--kill-after=1s", "5s", *command],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False,
        env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"},
    )
    report(name, command=command, exit_code=result.returncode,
           stdout=result.stdout[:4096], stderr=result.stderr[:4096],
           result="PASS" if result.returncode == 0 else "FAIL")
    return result.returncode == 0


report("platform", kernel=platform.release(), uid=os.getuid(), gid=os.getgid(),
       bwrap=shutil.which("bwrap"), unshare=shutil.which("unshare"))
for name, path in [
    ("os_release", "/etc/os-release"),
    ("unprivileged_userns_clone", "/proc/sys/kernel/unprivileged_userns_clone"),
    ("max_user_namespaces", "/proc/sys/user/max_user_namespaces"),
    ("apparmor_restrict_unprivileged_userns", "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"),
    ("apparmor_enabled", "/sys/module/apparmor/parameters/enabled"),
    ("LSM", "/sys/kernel/security/lsm"),
    ("current_profile", "/proc/self/attr/current"),
    ("current_apparmor_profile", "/proc/self/attr/apparmor/current"),
]:
    read_state(name, path)
read_state("process_security", "/proc/self/status",
           fields={"CapEff", "NoNewPrivs", "Seccomp", "Seccomp_filters"})
if os.getuid() == 0:
    report("os_isolation_prerequisites", result="BLOCKED", reason="root probes are not authorized")
    sys.exit(1)

checks = []
checks.append(probe("bwrap_version", [shutil.which("bwrap"), "--version"]))
checks.append(probe("userns_create", [shutil.which("unshare"), "--user", "/usr/bin/true"]))
checks.append(probe("userns_map_root", [shutil.which("unshare"), "-Ur", "/usr/bin/true"]))
checks.append(probe("proc_self_pid_namespace", [sys.executable, "-I", "-c",
    'import os; print(os.readlink("/proc/self/ns/pid"))']))
checks.append(probe("proc1_pid_namespace", [sys.executable, "-I", "-c",
    'import os; print(os.readlink("/proc/1/ns/pid"))']))
checks.append(probe("bwrap_worker_prerequisites", [shutil.which("bwrap"),
    "--unshare-user", "--unshare-pid", "--as-pid-1", "--die-with-parent",
    "--new-session", "--cap-drop", "ALL", "--bind", "/", "/",
    "--dev-bind", "/dev", "/dev", "--proc", "/proc",
    "--ro-bind", os.getcwd(), os.getcwd(), "--chdir", os.getcwd(),
    "--json-status-fd", "1", "--", "/usr/bin/true"]))
ready = all(checks)
report("os_isolation_prerequisites", result="PASS" if ready else "BLOCKED",
       os_tests_allowed=ready, reason="all required probes passed" if ready else "namespace or procfs prerequisite not met")
sys.exit(0 if ready else 1)
