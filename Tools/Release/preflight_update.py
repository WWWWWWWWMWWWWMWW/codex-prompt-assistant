"""Read-only update preflight; never stop, bootstrap, install or execute a bundle."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

from prepare_update import EXECUTABLE, inspect, require, verify_signature

HELPER = 'local.codex.prompt-assistant-app'
MODEL = 'local.codex.prompt-assistant-model'


def run_read_command(arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE,
                                   timeout=10, env=dict(os.environ, LC_ALL='C'))


def service_pid(label, runner=run_read_command):
    require(label in (HELPER, MODEL), 'unexpected_service_label')
    text = runner(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{label}'])
    states = re.findall(r'^\tstate = (.+)$', text, re.M)
    pids = re.findall(r'^\tpid = ([1-9][0-9]*)$', text, re.M)
    require(states == ['running'] and len(pids) == 1, 'service_not_running_or_unknown')
    return int(pids[0])


def process_identity(pid, runner):
    require(type(pid) is int and pid > 0, 'invalid_pid')
    text = runner(['/bin/ps', '-ww', '-p', str(pid), '-o', 'pid=,lstart=,comm='])
    match = re.fullmatch(r'\s*([1-9][0-9]*)\s+([^\n]{24})\s+(/[^\n]+)\n?', text)
    require(match is not None and int(match[1]) == pid, 'process_identity_unknown')
    return {'pid': pid, 'started': match[2], 'executable': match[3]}


def mapped_helper_file(pid, runner):
    text = runner(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-F', 'Dfin'])
    matches = []
    for record in re.split(r'(?m)(?=^f)', text):
        fields = {line[0]: line[1:] for line in record.splitlines() if line}
        if fields.get('f') == 'txt' and fields.get('n', '').endswith('/' + EXECUTABLE):
            try:
                matches.append({'path': fields['n'], 'inode': int(fields['i']),
                                'device': int(fields['D'], 16)})
            except (KeyError, ValueError):
                return None
    return matches[0] if len(matches) == 1 else None


def preflight(candidate, installed, codex_pid, model_pid, runner=run_read_command,
              signature_check=verify_signature):
    candidate, installed = Path(candidate).resolve(), Path(installed).resolve()

    def snapshot():
        helper_pid = service_pid(HELPER, runner)
        require(service_pid(MODEL, runner) == model_pid, 'model_pid_mismatch')
        require(len({helper_pid, codex_pid, model_pid}) == 3, 'process_identities_must_be_distinct')
        processes = {role: process_identity(pid, runner) for role, pid in
                     [('helper', helper_pid), ('codex', codex_pid), ('model', model_pid)]}
        require(processes['helper']['executable'] == str(installed / EXECUTABLE), 'helper_executable_mismatch')
        processes['helperMappedFile'] = mapped_helper_file(helper_pid, runner)
        return processes

    before = snapshot()
    bundles = {'candidate': inspect(candidate, signature_check), 'rollback': inspect(installed, signature_check)}
    capability = {}
    for role, path in [('candidate', candidate), ('rollback', installed)]:
        value = plistlib.loads((path / 'Contents/Info.plist').read_bytes()).get('CPAUpdateLifecycleVersion')
        capability[role] = type(value) is int and value == 1
        require(inspect(path, signature_check) == bundles[role], 'bundle_changed_during_preflight')
    require(before == snapshot(), 'process_changed_during_preflight')
    blockers = ['live_health_adapter_not_validated']
    executable = installed / EXECUTABLE
    expected_mapping = {'path': str(executable), 'inode': executable.stat().st_ino,
                        'device': executable.stat().st_dev}
    mapping_matches = before['helperMappedFile'] == expected_mapping
    if not mapping_matches:
        blockers.append('helper_mapped_executable_mismatch')
    for role in ('candidate', 'rollback'):
        if not capability[role]:
            blockers.append(role + '_lacks_model_preservation')
    return {'schema': 1, 'scope': 'read-only-preflight', 'automaticUpdateReady': False,
            'candidatePreservesResidentModel': capability['candidate'],
            'rollbackPreservesResidentModel': capability['rollback'],
            'helperMappedFileMatchesInstallation': mapping_matches,
            'processes': before, 'bundles': bundles, 'blockers': blockers}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--installed', type=Path, required=True)
    parser.add_argument('--codex-pid', type=int, required=True)
    parser.add_argument('--model-pid', type=int, required=True)
    args = parser.parse_args()
    try:
        report = preflight(args.candidate, args.installed, args.codex_pid, args.model_pid)
        print(json.dumps(report, indent=2))
        return 0 if report['automaticUpdateReady'] else 2
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        parser.exit(1, f'Preflight unknown/failed: {reason}; no mutation performed.\n')


if __name__ == '__main__':
    raise SystemExit(main())
