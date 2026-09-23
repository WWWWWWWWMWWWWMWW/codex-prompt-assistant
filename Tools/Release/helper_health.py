"""Bounded local health probes and conservative stopped-state checks. No service mutations."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

from helper_runtime import inspect_runtime
from preflight_update import HELPER, run_read_command
from prepare_update import EXECUTABLE, require


def probe_command(arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE, timeout=5)


def inspect_health(installed, expected_sha256, codex_pid, model_pid,
                   runtime_reader=inspect_runtime, probe=probe_command):
    installed = Path(installed)
    arguments = (installed, expected_sha256, codex_pid, model_pid)
    before = runtime_reader(*arguments)
    version = plistlib.loads((installed / 'Contents/Info.plist').read_bytes()).get('CPAHealthProtocolVersion')
    require(type(version) is int and version == 1, 'health_protocol_unavailable')
    pid = before['processes']['helper']['pid']
    started = time.monotonic()
    receipt = json.loads(probe([str(installed / EXECUTABLE), '--health-probe', str(pid)]))
    elapsed = time.monotonic() - started
    require(isinstance(receipt, dict) and type(receipt.get('schema')) is int and receipt['schema'] == 1,
            'invalid_health_schema')
    require(type(receipt.get('pid')) is int and receipt['pid'] == pid
            and type(receipt.get('uid')) is int and receipt['uid'] == os.getuid(), 'health_process_mismatch')
    require(receipt.get('build') == before['bundle']['build'], 'health_build_mismatch')
    for key in ('nonce', 'instance'):
        require(isinstance(receipt.get(key), str), 'invalid_health_identifier')
        uuid.UUID(receipt[key])
    require(elapsed <= 5, 'health_deadline_exceeded')
    after = runtime_reader(*arguments)
    require(before == after, 'runtime_changed_during_health_probe')
    fields = ('mainThreadResponsive', 'eventTapEnabled', 'accessibilityGranted', 'modelPreserved')
    require(all(type(receipt.get(key)) is bool for key in fields), 'invalid_health_state')
    healthy = all(receipt[key] for key in fields)
    # Emit only reviewed fields, never arbitrary response payload or input data.
    return {**after, 'scope': 'local-main-thread-and-input-health', 'healthVerified': healthy,
            'health': {key: receipt[key] for key in fields}, 'instance': receipt['instance'],
            'responseMilliseconds': round(elapsed * 1000),
            'blockers': [item for item in after['blockers'] if item != 'live_health_not_verified']
                        + ([] if healthy else ['current_input_health_unavailable']),
            'automaticUpdateReady': False,
            'note': 'Fresh main-thread response and input state only; not model generation or host insertion acceptance.'}


def helper_stopped(old_pid, runner=run_read_command, signal_probe=os.kill):
    """True only for explicit service absence plus ESRCH for the exact old PID.

    False means at least one is still present; None means unknown. Never stop or
    signal a process (signal zero only), and never infer absence from any error.
    """
    require(type(old_pid) is int and old_pid > 0, 'invalid_old_helper_pid')
    target = f'gui/{os.getuid()}/{HELPER}'
    try:
        runner(['/bin/launchctl', 'print', target])
        return False
    except subprocess.CalledProcessError as error:
        stderr = error.stderr.decode(errors='replace') if isinstance(error.stderr, bytes) else (error.stderr or '')
        expected = f'Bad request.\nCould not find service "{HELPER}" in domain for user gui: {os.getuid()}'
        if error.returncode != 113 or stderr.strip() != expected:
            return None
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        signal_probe(old_pid, 0)
        return False
    except ProcessLookupError:
        return True
    except OSError:
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installed', type=Path, default=Path.home() / 'Applications/CodexPromptAssistantPOC.app')
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--codex-pid', type=int, required=True)
    parser.add_argument('--model-pid', type=int, required=True)
    args = parser.parse_args()
    try:
        report = inspect_health(args.installed, args.expected_sha256, args.codex_pid, args.model_pid)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0 if report['healthVerified'] else 2
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        parser.exit(1, f'Health check unknown/failed: {type(error).__name__}; no service mutation performed.\n')


if __name__ == '__main__':
    raise SystemExit(main())
