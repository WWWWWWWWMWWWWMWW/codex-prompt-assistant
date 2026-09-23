import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[2] / 'Tools/Release'
sys.path.insert(0, str(TOOLS))
import preflight_update as preflight
import prepare_update as preparation


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['CPA_TEST_ROOT'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.candidate = self.bundle('candidate.app', 1)
        self.installed = self.bundle('installed.app', 0)
        self.calls = []
        self.mismatch = False
        self.mapped_mismatch = False

    def bundle(self, name, capability):
        path = self.root / name
        executable = path / preparation.EXECUTABLE
        executable.parent.mkdir(parents=True)
        executable.write_text('synthetic fixture only')
        executable.chmod(0o755)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': preparation.IDENTIFIER,
            'CFBundleExecutable': Path(preparation.EXECUTABLE).name,
            'CPAUpdateLifecycleVersion': capability,
            'CPABuildMetadata': {'SchemaVersion': 1, 'GitCommit': 'a' * 40, 'WorktreeDirty': False}}))
        return path

    def runner(self, args):
        self.calls.append(args)
        if args[:2] == ['/bin/launchctl', 'print']:
            pid = 11 if args[2].endswith('-app') else 22
            return '\tstate = running\n\tpid = ' + str(pid) + '\n'
        if args[0] == '/usr/sbin/lsof':
            path = self.installed.resolve() / preparation.EXECUTABLE
            inode = path.stat().st_ino + (1 if self.mapped_mismatch else 0)
            return f'p11\nftxt\nD{hex(path.stat().st_dev)}\ni{inode}\nn{path}\n'
        self.assertEqual(args[:2], ['/bin/ps', '-ww'])
        pid = int(args[3])
        executable = str(self.installed.resolve() / preparation.EXECUTABLE) if pid == 11 else '/fixture/process'
        if self.mismatch and pid == 11:
            executable = '/fixture/unexpected-helper'
        return f'{pid} Tue Sep  8 11:52:44 2026 {executable}\n'

    def report(self, **options):
        return preflight.preflight(self.candidate, self.installed, 33, 22,
            runner=self.runner, signature_check=lambda _: None, **options)

    def test_old_package_is_blocked_and_snapshot_is_read_only(self):
        report = self.report()
        self.assertFalse(report['automaticUpdateReady'])
        self.assertIn('rollback_lacks_model_preservation', report['blockers'])
        self.assertTrue(report['candidatePreservesResidentModel'])
        self.assertEqual(report['processes']['helper']['pid'], 11)
        self.assertTrue(all(args[:2] in (['/bin/launchctl', 'print'], ['/bin/ps', '-ww'])
                            or args[0] == '/usr/sbin/lsof' for args in self.calls))

    def test_even_capable_packages_do_not_skip_running_identity_gate(self):
        self.installed = self.bundle('capable.app', 1)
        report = self.report()
        self.assertNotIn('rollback_lacks_model_preservation', report['blockers'])
        self.assertIn('live_health_adapter_not_validated', report['blockers'])
        self.assertFalse(report['automaticUpdateReady'])

    def test_wrong_helper_path_and_wrong_model_pid_are_rejected(self):
        self.mismatch = True
        with self.assertRaisesRegex(ValueError, 'helper_executable_mismatch'):
            self.report()
        with self.assertRaisesRegex(ValueError, 'model_pid_mismatch'):
            preflight.preflight(self.candidate, self.installed, 33, 999,
                runner=self.runner, signature_check=lambda _: None)

    def test_service_parser_does_not_treat_unknown_or_nested_pid_as_running(self):
        for text in ('', '\tstate = waiting\n\tpid = 11\n',
                     '\tstate = running\n\t\tpid = 11\n',
                     '\tstate = running\n\tpid = 11\n\tpid = 12\n'):
            with self.assertRaises(ValueError):
                preflight.service_pid('local.codex.prompt-assistant-app', lambda _: text)

    def test_process_change_between_snapshots_is_rejected(self):
        original = self.runner
        count = 0
        def changing(args):
            nonlocal count
            text = original(args)
            if args[:2] == ['/bin/ps', '-ww']:
                count += 1
                if count > 3:
                    text = text.replace('11:52:44', '11:53:44')
            return text
        with self.assertRaisesRegex(ValueError, 'process_changed_during_preflight'):
            preflight.preflight(self.candidate, self.installed, 33, 22,
                runner=changing, signature_check=lambda _: None)

    def test_command_failure_remains_unknown(self):
        def failed(args):
            raise subprocess.CalledProcessError(5, args)
        with self.assertRaises(subprocess.CalledProcessError):
            preflight.service_pid('local.codex.prompt-assistant-model', failed)

    def test_mapped_file_mismatch_blocks_even_when_ps_and_disk_match(self):
        self.mapped_mismatch = True
        report = self.report()
        self.assertIn('helper_mapped_executable_mismatch', report['blockers'])
        self.assertFalse(report['helperMappedFileMatchesInstallation'])

    def test_matching_mapping_uses_device_inode_and_path(self):
        report = self.report()
        self.assertTrue(report['helperMappedFileMatchesInstallation'])
        self.assertEqual(report['processes']['helperMappedFile']['inode'],
                         (self.installed / preparation.EXECUTABLE).stat().st_ino)


if __name__ == '__main__':
    unittest.main()
