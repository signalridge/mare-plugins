"""Own PTY test resources across failures, timeouts and termination signals."""

import os
import signal
import subprocess
import tempfile
import threading
from contextlib import ExitStack
from functools import wraps

_local = threading.local()
_active = set()
_lock = threading.RLock()


def scoped(function):
    @wraps(function)
    def run(*args, **kwargs):
        with ExitStack() as stack:
            _local.stack = stack
            with _lock:
                _active.add(stack)
            try:
                return function(*args, **kwargs)
            finally:
                with _lock:
                    stack.close()
                    _active.discard(stack)

    return run


def directory(prefix):
    with _lock:
        if _local.stack not in _active:
            raise SystemExit("PTY cleanup already started")
        return _local.stack.enter_context(tempfile.TemporaryDirectory(prefix=prefix))


def descriptor(fd):
    def close():
        try:
            os.close(fd)
        except OSError:
            pass

    with _lock:
        _local.stack.callback(close)
    return fd


def process(child):
    def stop():
        # Each PTY child starts a session: terminate its tools as well as mare before
        # removing their cwd/home. SIGKILL also bounds cleanup when shutdown is stuck.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=5)

    with _lock:
        _local.stack.callback(stop)
    return child


def main(function):
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)

    previous = {s: signal.signal(s, terminate) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        function()
    finally:
        with _lock:
            for stack in list(_active):
                stack.close()
            _active.clear()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def spawn(slave, *args, **kwargs):
    with _lock:
        try:
            if _local.stack not in _active:
                raise SystemExit("PTY cleanup already started")
            # SIGKILL bypasses child destructors: its temporary files belong to this
            # parent scope too. Register before process() so LIFO teardown reaps first.
            temporary = directory("mare-ptyt-tmp-")
            inherited = kwargs.get("env")
            child_env = os.environ.copy() if inherited is None else dict(inherited)
            child_env.update(TMPDIR=temporary, TEMP=temporary, TMP=temporary)
            kwargs["env"] = child_env
            return process(subprocess.Popen(*args, **kwargs))
        finally:
            os.close(slave)
