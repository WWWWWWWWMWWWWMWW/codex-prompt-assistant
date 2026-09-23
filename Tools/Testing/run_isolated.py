#!/usr/bin/env python3
"""Run a default suite with private fixture resources and bounded write protections."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

def sandbox_profile(home):
    home = home.resolve()
    protected = [home / 'Applications',
        home / 'Library/Application Support/CodexPromptAssistant',
        home / 'Library/LaunchAgents/local.codex.prompt-assistant-app.plist',
        home / 'Library/LaunchAgents/local.codex.prompt-assistant-model.plist']
    paths = ' '.join('(subpath ' + json.dumps(str(path), ensure_ascii=False) + ')'
        for path in protected)
    return ('(version 1)(allow default)(deny network*)'
        '(deny file-write* (regex "^(/private)?/tmp/CodexPromptAssistantPOC-diagnostic[.]log"))'
        '(deny file-write* ' + paths + ')'
        '(deny process-exec (literal "/bin/launchctl"))')

class Terminated(Exception):
    def __init__(self, signum):
        self.signum = signum

def main(argv):
    if not argv:
        return 2
    child = None
    previous = {}
    def terminate(signum, _frame):
        raise Terminated(signum)
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.signal(sig, terminate)
    try:
        # Existing executables share .build/tests; serialize public suite runs.
        lock_path = Path(__file__).resolve().parents[2] / '.build/tests/.isolation.lock'
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with tempfile.TemporaryDirectory(prefix='cpa-tests-', dir='/tmp') as root:
                environment = dict(os.environ, CPA_TEST_ROOT=root)
                print('Test resources: private diagnostics and fixture credentials; network denied', flush=True)
                try:
                    child = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', sandbox_profile(Path.home()), *argv],
                        env=environment, start_new_session=True)
                    code = child.wait()
                    return code if code >= 0 else 128 - code
                finally:
                    if child is not None and child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()
    except Terminated as error:
        return 128 + error.signum
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
