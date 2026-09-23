"""Prepare a reviewable helper LaunchAgent. Never install, launch or stop a service."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

from prepare_update import (EXECUTABLE, IDENTIFIER, require, sha256, tree_digest,
                            verify_signature, write_manifest)

LABEL = 'local.codex.prompt-assistant-app'
REPOSITORY = Path(__file__).resolve().parents[2]


def configuration(user_home):
    user_home = Path(user_home)
    require(user_home.is_absolute() and user_home.is_dir(), 'home must be an existing absolute directory')
    require(not any(c in str(user_home) for c in ('\n', '\r', '\x00')), 'unsupported home path')
    require(user_home.resolve() == user_home, 'home path must not contain symlinks')
    executable = user_home / 'Applications/CodexPromptAssistantPOC.app' / EXECUTABLE
    return {'Label': LABEL, 'ProgramArguments': [str(executable), '--preserve-resident-model'],
            'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 30,
            'ProcessType': 'Interactive', 'LimitLoadToSessionType': 'Aqua'}


def inspect_for_preparation(bundle, expected_sha256, signature_check):
    # Local dirty packages may be inspected for configuration only. This does not
    # relax prepare_update.inspect's separate clean-release requirement.
    require(re.fullmatch(r'[0-9a-f]{64}', expected_sha256), 'expected executable SHA256 is required')
    require(bundle.resolve() == bundle, 'bundle path must not contain symlinks')
    before = tree_digest(bundle)
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    require(isinstance(info, dict), 'invalid bundle plist')
    require(info.get('CFBundleIdentifier') == IDENTIFIER, 'unexpected bundle identifier')
    require(info.get('CFBundleExecutable') == Path(EXECUTABLE).name, 'unexpected executable')
    lifecycle = info.get('CPAUpdateLifecycleVersion')
    require(type(lifecycle) is int and lifecycle == 1, 'resident-model preservation is required')
    metadata = info.get('CPABuildMetadata')
    require(isinstance(metadata, dict), 'build metadata is required')
    require(type(metadata.get('SchemaVersion')) is int and metadata['SchemaVersion'] == 1,
            'unsupported metadata schema')
    require(type(metadata.get('WorktreeDirty')) is bool, 'unknown worktree identity')
    require(re.fullmatch(r'[0-9a-f]{40}', str(metadata.get('GitCommit', ''))), 'invalid build commit')
    require(os.access(bundle / EXECUTABLE, os.X_OK), 'helper is not executable')
    signature_check(bundle)
    require(sha256(bundle / EXECUTABLE) == expected_sha256, 'executable SHA256 mismatch')
    require(tree_digest(bundle) == before, 'bundle changed during inspection')
    return {'executableSHA256': expected_sha256, 'treeSHA256': before, 'build': metadata}


def prepare(user_home, output, expected_sha256, signature_check=verify_signature):
    config = configuration(user_home)
    bundle = Path(user_home) / 'Applications/CodexPromptAssistantPOC.app'
    output = Path(output)
    require(output.is_absolute() and output.resolve() == output, 'output must be an absolute path without symlinks')
    require(not output.exists() and not output.is_symlink(), 'output already exists; choose a new name')
    require(output != bundle and bundle not in output.parents and output not in bundle.parents,
            'output must not overlap the bundle')
    before = inspect_for_preparation(bundle, expected_sha256, signature_check)
    output.mkdir(mode=0o700)
    destination = output / (LABEL + '.plist')
    with destination.open('xb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(plistlib.dumps(config, sort_keys=False))
        stream.flush()
        os.fsync(stream.fileno())
    require(plistlib.loads(destination.read_bytes()) == config, 'prepared configuration mismatch')
    require(inspect_for_preparation(bundle, expected_sha256, signature_check) == before,
            'bundle changed during preparation')
    report = {'schema': 1, 'scope': 'helper-agent-preparation-only',
              'state': 'prepared-configuration-only', 'installationReady': False,
              'targetBundle': str(bundle), 'bundle': before,
              'configurationFile': destination.name, 'configurationSHA256': sha256(destination),
              'preservesResidentModel': True,
              'notVerified': ['service configuration migration', 'launchd start and stop',
                              'clean-user authorization', 'real rollback', 'model/service supply'],
              'note': 'Review only. No bundle copied, LaunchAgent installed, service changed or model started.'}
    write_manifest(output, report)
    return report


def preparation_output(name):
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', name), 'invalid preparation name')
    parent = REPOSITORY / '.build/helper-agent-preparations'
    require(parent.resolve() == parent, 'preparation parent must not contain symlinks')
    parent.mkdir(parents=True, exist_ok=True)
    return parent / name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, default=Path.home(), help='Target user with an installed helper bundle')
    parser.add_argument('--expected-sha256', required=True, help='Previously verified installed executable SHA256')
    parser.add_argument('--name', required=True, help='New directory under .build/helper-agent-preparations')
    args = parser.parse_args()
    try:
        output = preparation_output(args.name)
        result = prepare(args.home, output, args.expected_sha256)
        print(json.dumps({'directory': str(output), **result}, ensure_ascii=False, indent=2))
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        parser.exit(1, f'Preparation failed: {reason}; no installation or service action performed.\n')


if __name__ == '__main__':
    main()
