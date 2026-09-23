"""Inspect the running helper and model protection. No service mutations or health claims."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

from helper_agent import configuration, inspect_for_preparation
from preflight_update import HELPER, MODEL, mapped_helper_file, process_identity, run_read_command, service_pid
from prepare_update import EXECUTABLE, require, verify_signature


def parse_helper_service(text):
    def field(name):
        values = re.findall(r'^\t' + name + r' = ([^\n]+)$', text, re.M)
        require(len(values) == 1, 'helper_service_' + name + '_unknown')
        return values[0]
    require(field('state') == 'running', 'helper_not_known_running')
    pid = field('pid')
    require(re.fullmatch(r'[1-9][0-9]*', pid), 'helper_pid_unknown')
    blocks = re.findall(r'^\targuments = \{\n(.*?)^\t\}', text, re.M | re.S)
    require(len(blocks) == 1, 'helper_arguments_unknown')
    lines = blocks[0].splitlines()
    require(lines and all(line.startswith('\t\t') and not line.startswith('\t\t\t') for line in lines),
            'helper_arguments_unknown')
    return {'pid': int(pid), 'path': field('path'), 'program': field('program'),
            'arguments': [line[2:] for line in lines]}


def inspect_runtime(installed, expected_sha256, codex_pid, model_pid,
                    runner=run_read_command, signature_check=verify_signature):
    installed = Path(installed)
    require(installed.is_absolute() and installed.resolve() == installed,
            'installed_path_must_be_absolute_without_links')
    user_home = installed.parent.parent
    expected_config = configuration(user_home)
    executable = installed / EXECUTABLE
    require(str(executable) == expected_config['ProgramArguments'][0], 'unexpected_installation_path')

    def snapshot():
        service = parse_helper_service(runner(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{HELPER}']))
        require(service['program'] == str(executable), 'loaded_helper_program_mismatch')
        require(service['arguments'] == expected_config['ProgramArguments'], 'loaded_helper_protection_mismatch')
        config_path = Path(service['path'])
        require(config_path.is_absolute() and config_path.is_relative_to(user_home)
                and config_path.resolve() == config_path and config_path.is_file(), 'service_config_path_unsupported')
        # No pipes, executable evaluation, unbounded reads or raw config output.
        with config_path.open('rb') as stream:
            data = stream.read(65537)
        require(len(data) <= 65536, 'service_config_too_large')
        config = plistlib.loads(data)
        require(config == expected_config, 'disk_and_expected_service_configuration_mismatch')
        require(service_pid(MODEL, runner) == model_pid, 'model_pid_mismatch')
        require(len({service['pid'], codex_pid, model_pid}) == 3, 'process_identities_must_be_distinct')
        processes = {role: process_identity(pid, runner) for role, pid in
                     [('helper', service['pid']), ('codex', codex_pid), ('model', model_pid)]}
        require(processes['helper']['executable'] == str(executable), 'helper_process_path_mismatch')
        process_args = runner(['/bin/ps', '-ww', '-p', str(service['pid']), '-o', 'args=']).strip()
        # ps is unquoted display text. Accept only the exact two-argument shape
        # also established independently from launchd's separate argument lines.
        require(process_args == ' '.join(expected_config['ProgramArguments']), 'running_helper_protection_mismatch')
        mapping = mapped_helper_file(service['pid'], runner)
        expected_mapping = {'path': str(executable), 'inode': executable.stat().st_ino,
                            'device': executable.stat().st_dev}
        require(mapping == expected_mapping, 'helper_mapped_executable_mismatch')
        return {'processes': processes, 'mappedFile': mapping, 'servicePath': str(config_path),
                'serviceSHA256': hashlib.sha256(data).hexdigest()}

    bundle = inspect_for_preparation(installed, expected_sha256, signature_check)
    before = snapshot()
    require(inspect_for_preparation(installed, expected_sha256, signature_check) == bundle,
            'bundle_changed_during_runtime_inspection')
    after = snapshot()
    require(before == after, 'runtime_changed_during_inspection')
    # A stable process and mapped executable do not prove the event tap, main
    # thread, model, or UI are responsive. Never promote historical startup logs.
    blockers = ['live_health_not_verified', 'stopped_state_not_verified', 'real_rollback_not_verified']
    if bundle['build']['WorktreeDirty']:
        blockers.append('dirty_build_not_release_candidate')
    return {'schema': 1, 'scope': 'read-only-running-helper', 'runtimeIdentityVerified': True,
            'modelProtectionVerified': True, 'healthVerified': False, 'automaticUpdateReady': False,
            'bundle': bundle, **after, 'blockers': blockers,
            'note': 'No service mutation, app execution, model request, permission change or log-based health inference.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installed', type=Path, default=Path.home() / 'Applications/CodexPromptAssistantPOC.app')
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--codex-pid', type=int, required=True)
    parser.add_argument('--model-pid', type=int, required=True)
    args = parser.parse_args()
    try:
        report = inspect_runtime(args.installed, args.expected_sha256, args.codex_pid, args.model_pid)
        print(json.dumps(report, ensure_ascii=False, indent=2))
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        # Never echo command output, user configuration or process argument text.
        reason = str(error) if type(error) is ValueError else type(error).__name__
        parser.exit(1, f'Runtime inspection unknown/failed: {reason}; no mutation performed.\n')


if __name__ == '__main__':
    main()
