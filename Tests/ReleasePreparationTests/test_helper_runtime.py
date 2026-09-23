import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools/Release'))
import helper_runtime as runtime
from helper_agent import configuration
from prepare_update import EXECUTABLE, IDENTIFIER, sha256


class RuntimeInspectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['CPA_TEST_ROOT'])
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve() / '用户 with spaces'
        self.bundle = self.home / 'Applications/CodexPromptAssistantPOC.app'
        self.binary = self.bundle / EXECUTABLE
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text('fixture never execute'); self.binary.chmod(0o755)
        (self.bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': IDENTIFIER, 'CFBundleExecutable': self.binary.name,
            'CPAUpdateLifecycleVersion': 1,
            'CPABuildMetadata': {'SchemaVersion': 1, 'GitCommit': 'a' * 40, 'WorktreeDirty': True}}))
        self.config = self.home / 'guarded.plist'
        self.config.write_bytes(plistlib.dumps(configuration(self.home)))
        self.expected = sha256(self.binary)
        self.arguments = [str(self.binary), '--preserve-resident-model']
        self.process_args = ' '.join(self.arguments)
        self.inode_delta = 0
        self.calls = []
        self.helper_reads = 0

    def service_text(self):
        return (f'\tpath = {self.config}\n\tstate = running\n\tprogram = {self.binary}\n'
                '\targuments = {\n' + ''.join('\t\t' + arg + '\n' for arg in self.arguments) +
                '\t}\n\tpid = 11\n')

    def runner(self, args):
        self.calls.append(args)
        if args[:2] == ['/bin/launchctl', 'print']:
            if args[2].endswith('-app'):
                self.helper_reads += 1
                return self.service_text()
            return '\tstate = running\n\tpid = 22\n'
        if args[0] == '/usr/sbin/lsof':
            return f'p11\nftxt\nD{hex(self.binary.stat().st_dev)}\ni{self.binary.stat().st_ino + self.inode_delta}\nn{self.binary}\n'
        if args[0] == '/bin/ps' and args[-1] == 'args=':
            return self.process_args + '\n'
        if args[0] == '/bin/ps':
            pid = int(args[3])
            executable = str(self.binary) if pid == 11 else '/fixture/protected'
            return f'{pid} Thu Sep 17 10:00:00 2026 {executable}\n'
        raise AssertionError('unexpected command')

    def inspect(self, **overrides):
        args = dict(installed=self.bundle, expected_sha256=self.expected, codex_pid=33,
                    model_pid=22, runner=self.runner, signature_check=lambda _: None)
        args.update(overrides)
        return runtime.inspect_runtime(**args)

    def test_live_identity_does_not_claim_health_or_permission_to_update(self):
        before = self.config.read_bytes()
        result = self.inspect()
        self.assertTrue(result['runtimeIdentityVerified'])
        self.assertTrue(result['modelProtectionVerified'])
        self.assertFalse(result['healthVerified'])
        self.assertFalse(result['automaticUpdateReady'])
        self.assertIn('live_health_not_verified', result['blockers'])
        self.assertTrue(result['bundle']['build']['WorktreeDirty'])
        self.assertEqual(self.helper_reads, 2)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertTrue(all(call[0] in ['/bin/launchctl', '/bin/ps', '/usr/sbin/lsof'] for call in self.calls))
        self.assertTrue(all(call[1] == 'print' for call in self.calls if call[0] == '/bin/launchctl'))

    def test_missing_extra_and_lookalike_loaded_arguments_rejected(self):
        for arguments in [[str(self.binary)], [str(self.binary), '--preserve-resident-model=false'],
                          self.arguments + ['--unexpected'], ['/bin/sh', '-c', 'exec fixture']]:
            self.arguments = arguments
            with self.subTest(arguments=arguments), self.assertRaises(ValueError): self.inspect()

    def test_process_arguments_must_match_not_just_contain_protection_flag(self):
        for value in [str(self.binary), self.process_args + '=false', self.process_args + ' --extra']:
            self.process_args = value
            with self.subTest(value=value), self.assertRaises(ValueError): self.inspect()

    def test_disk_configuration_must_match_loaded_program_and_policy(self):
        config = configuration(self.home)
        for replacement in [dict(config, ProgramArguments=[str(self.binary)]),
                            dict(config, EnvironmentVariables={'fixture': 'value'}),
                            dict(config, Label='other')]:
            self.config.write_bytes(plistlib.dumps(replacement))
            with self.assertRaises(ValueError): self.inspect()

    def test_parser_rejects_duplicate_nested_and_missing_identity_fields(self):
        valid = self.service_text()
        for text in [valid + '\tpid = 12\n', valid.replace('\tpid =', '\t\tpid ='),
                     valid.replace('state = running', 'state = waiting'),
                     valid + '\tpath = /another\n', valid.replace('\targuments = {', '\t\targuments = {')]:
            with self.subTest(text=text), self.assertRaises(ValueError): runtime.parse_helper_service(text)

    def test_wrong_mapping_and_protected_pid_rejected(self):
        self.inode_delta = 1
        with self.assertRaises(ValueError): self.inspect()
        self.inode_delta = 0
        for overrides in [{'model_pid': 999}, {'codex_pid': 11}, {'codex_pid': 22}]:
            with self.assertRaises(ValueError): self.inspect(**overrides)

    def test_configuration_replaced_during_signature_check_is_rejected(self):
        calls = 0
        def change(_):
            nonlocal calls
            calls += 1
            if calls == 2:
                self.config.write_bytes(plistlib.dumps(dict(configuration(self.home), ThrottleInterval=99)))
        with self.assertRaises(ValueError): self.inspect(signature_check=change)

    def test_command_failure_is_not_echoed_by_cli(self):
        from unittest.mock import patch
        import io
        args = ['helper_runtime.py', '--installed', str(self.bundle), '--expected-sha256', self.expected,
                '--codex-pid', '33', '--model-pid', '22']
        with patch('sys.argv', args), patch.object(runtime, 'inspect_runtime',
                side_effect=subprocess.CalledProcessError(5, ['fixture-private-value'], output='fixture-private-output')), \
                patch('sys.stderr', new_callable=io.StringIO) as output, self.assertRaises(SystemExit) as error:
            runtime.main()
        self.assertEqual(error.exception.code, 1)
        self.assertNotIn('fixture-private', output.getvalue())

    def test_config_size_bound_and_wrong_expected_package_rejected(self):
        with self.assertRaises(ValueError): self.inspect(expected_sha256='0' * 64)
        self.config.write_bytes(b'x' * 65537)
        with self.assertRaises(ValueError): self.inspect()

    def test_process_start_time_change_between_snapshots_is_rejected(self):
        original = self.runner
        def change(args):
            result = original(args)
            if self.helper_reads >= 2 and args[0] == '/bin/ps':
                result = result.replace('10:00:00', '10:00:01')
            return result
        with self.assertRaises(ValueError): self.inspect(runner=change)

    def test_config_link_and_fifo_rejected_without_opening(self):
        actual = self.home / 'actual'; self.config.rename(actual); self.config.symlink_to(actual)
        with self.assertRaises(ValueError): self.inspect()
        self.config.unlink(); os.mkfifo(self.config)
        with self.assertRaises(ValueError): self.inspect()

    def test_command_failure_is_unknown_not_stopped(self):
        def fail(args): raise subprocess.CalledProcessError(5, args)
        with self.assertRaises(subprocess.CalledProcessError): self.inspect(runner=fail)


if __name__ == '__main__':
    unittest.main()
