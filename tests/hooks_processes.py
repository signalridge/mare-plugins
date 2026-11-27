"""Observe only a test-owned server's descendants; namespace PIDs are not host PIDs."""

import ctypes
import os
import subprocess
from pathlib import Path


def _windows_pid_alive(pid):
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    STILL_ACTIVE = 259
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return False
        return code.value == STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def _windows_children_map():
    TH32CS_SNAPPROCESS = 0x00000002
    INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

    class PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [
            ("dwSize", ctypes.c_ulong),
            ("cntUsage", ctypes.c_ulong),
            ("th32ProcessID", ctypes.c_ulong),
            ("th32DefaultHeapID", ctypes.c_size_t),
            ("th32ModuleID", ctypes.c_ulong),
            ("cntThreads", ctypes.c_ulong),
            ("th32ParentProcessID", ctypes.c_ulong),
            ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", ctypes.c_ulong),
            ("szExeFile", ctypes.c_wchar * 260),
        ]

    kernel32 = ctypes.windll.kernel32
    snap = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == INVALID_HANDLE_VALUE:
        return {}
    children = {}
    try:
        entry = PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
        ok = kernel32.Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            children.setdefault(int(entry.th32ParentProcessID), []).append(int(entry.th32ProcessID))
            ok = kernel32.Process32NextW(snap, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snap)
    return children


def _posix_children_map():
    out = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True, encoding="utf-8")
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    return children


def is_pid_alive(pid):
    pid = int(pid)
    if os.name == "nt":
        return _windows_pid_alive(pid)
    if Path("/proc").is_dir():
        return Path(f"/proc/{pid}").exists()
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def host_processes(server_pid, namespace_pid):
    server_pid = int(server_pid)
    namespace_pid = int(namespace_pid)
    proc_children = Path(f"/proc/{server_pid}/task/{server_pid}/children")
    if proc_children.exists():
        descendants = []
        pending = [server_pid]
        while pending:
            parent = pending.pop()
            children_file = Path(f"/proc/{parent}/task/{parent}/children")
            try:
                values = children_file.read_text(encoding="utf-8").split()
            except OSError:
                values = []
            for value in values:
                child = int(value)
                descendants.append(child)
                pending.append(child)
        assert descendants, "no actual hook descendants were observed"
        matches = []
        for pid in descendants:
            try:
                status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8")
            except OSError:
                continue
            namespace = next((line for line in status.splitlines() if line.startswith("NSpid:")), "")
            if namespace and int(namespace.split()[-1]) == namespace_pid:
                matches.append(pid)
        assert matches and all(pid > 2 for pid in matches), (namespace_pid, descendants)
        return matches

    children_map = _windows_children_map() if os.name == "nt" else _posix_children_map()
    descendants = []
    seen = {server_pid}
    pending = [server_pid]
    while pending:
        parent = pending.pop()
        for child in children_map.get(parent, ()):
            if child not in seen:
                seen.add(child)
                descendants.append(child)
                pending.append(child)
    assert descendants, "no actual hook descendants were observed"
    matches = [pid for pid in descendants if pid == namespace_pid]
    assert matches and all(pid > 2 for pid in matches), (namespace_pid, descendants)
    return matches


def assert_reaped(pids):
    for pid in pids:
        assert not is_pid_alive(pid), f"actual hook process {pid} was not reaped"
