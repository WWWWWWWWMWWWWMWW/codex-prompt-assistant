import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools/Release'))
import helper_launchd_services as services
from helper_agent import configuration
import prepare_update as preparation
import update_transaction as transaction


class HelperLaunchdTests(unittest.TestCase):
    """Real adapter + transaction + runtime parser; fake OS/signature/health only."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['CPA_TEST_ROOT'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / '用户 with spaces'
        self.installed = self.bundle('Applications/CodexPromptAssistantPOC.app', 'a')
        self.candidate = self.bundle('candidate.app', 'b')
        self.binary = self.installed / preparation.EXECUTABLE
        self.plist = self.root / 'guarded-helper.plist'
        self.plist.write_bytes(plistlib.dumps(configuration(self.root)))
        self.old = preparation.inspect(self.installed, lambda _: None)
        self.new = preparation.inspect(self.candidate, lambda _: None)
        self.prepared = self.root / 'prepared'
        preparation.prepare(self.candidate, self.installed, self.prepared, 'b' * 40,
                            self.old['executableSHA256'], lambda _: None, shutil.copytree)
        self.calls, self.mutations, self.waits = [], [], []
        self.pid, self.running, self.old_alive = 11, True, False
        self.model_pid, self.started = 22, 'Thu Sep 17 10:00:00 2026'
        self.arguments = [str(self.binary), '--preserve-resident-model']
        self.loaded_path = self.plist
        self.absence_error, self.after_stop, self.after_start = None, None, None
        self.no_start, self.waiting, self.no_stop = False, False, False
        self.fail_health = set()
        self.adapter = self.construct()

    def bundle(self, name, commit):
        path = self.root / name
        binary = path / preparation.EXECUTABLE
        binary.parent.mkdir(parents=True)
        binary.write_text('fixture never execute ' + commit); binary.chmod(0o755)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': preparation.IDENTIFIER,
            'CFBundleExecutable': binary.name,
            'CPAUpdateLifecycleVersion': 1, 'CPAHealthProtocolVersion': 1,
            'CPABuildMetadata': {'SchemaVersion': 1, 'GitCommit': commit * 40, 'WorktreeDirty': False}}))
        return path

    def construct(self, **options):
        return services.HelperLaunchdServices(self.installed, self.plist,
            preparation.sha256(self.binary), 33, 22, runner=self.runner,
            signal_probe=self.signal_probe, signature_check=lambda _: None,
            health_reader=self.health, wait=self.waits.append, attempts=3, **options)

    def runner(self, args):
        self.calls.append(args)
        if args[:2] == ['/bin/launchctl', 'print']:
            if args[2].endswith('-model'):
                return f'\tstate = running\n\tpid = {self.model_pid}\n'
            if self.waiting:
                return '\tstate = waiting\n'
            if not self.running:
                if self.absence_error:
                    raise subprocess.CalledProcessError(5, args, stderr=self.absence_error)
                raise subprocess.CalledProcessError(113, args, stderr=
                    f'Bad request.\nCould not find service "{services.HELPER}" in domain for user gui: {os.getuid()}\n')
            return (f'\tpath = {self.loaded_path}\n\tstate = running\n\tprogram = {self.binary}\n'
                    '\targuments = {\n' + ''.join('\t\t' + arg + '\n' for arg in self.arguments)
                    + f'\t}}\n\tpid = {self.pid}\n')
        if args[:2] == ['/bin/launchctl', 'bootout']:
            self.assertEqual(args[2], f'gui/{os.getuid()}/{services.HELPER}')
            self.mutations.append('stop')
            if not self.no_stop: self.running = False
            if self.after_stop: self.after_stop()
            return ''
        if args[:2] == ['/bin/launchctl', 'bootstrap']:
            self.assertEqual(args[2:], [f'gui/{os.getuid()}', str(self.plist)])
            self.mutations.append('start')
            if not self.no_start:
                self.running = True; self.pid += 1
            if self.after_start: self.after_start()
            return ''
        if args[0] == '/usr/sbin/lsof':
            return f'p{self.pid}\nftxt\nD{hex(self.binary.stat().st_dev)}\ni{self.binary.stat().st_ino}\nn{self.binary}\n'
        if args[0] == '/bin/ps' and args[-1] == 'args=':
            return ' '.join(self.arguments) + '\n'
        if args[0] == '/bin/ps':
            pid = int(args[3])
            executable = str(self.binary) if pid == self.pid else f'/fixture/protected{pid}'
            return f'{pid} {self.started} {executable}\n'
        raise AssertionError(args)

    def signal_probe(self, pid, signal):
        self.assertEqual(signal, 0)
        if self.old_alive or (self.running and pid == self.pid): return
        raise ProcessLookupError()

    def health(self, installed, digest, codex, model, runtime_reader):
        result = runtime_reader(installed, digest, codex, model)
        return dict(result, healthVerified=result['bundle']['build']['GitCommit'][0] not in self.fail_health)

    def run_update(self, **options):
        return transaction.update(self.prepared, self.installed, self.adapter,
            signature_check=lambda _: None, copier=options.pop('copier', shutil.copytree), **options)

    def assert_outcome(self, outcome, mutations, **options):
        result = self.run_update(**options)
        self.assertEqual(result['outcome'], outcome, result)
        self.assertEqual(self.mutations, mutations)
        return result

    def test_success_and_package_gap(self):
        result = self.assert_outcome('updated', ['stop', 'start'])
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.new)
        self.assertEqual(preparation.inspect(Path(result['directory']) / 'original.app', lambda _: None), self.old)
        self.assertEqual(self.adapter._helper['pid'], 12)

    def test_failed_health_rolls_back_exactly_once(self):
        self.fail_health = {'b'}
        self.assert_outcome('rolled_back', ['stop', 'start', 'stop', 'start'])
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.old)
        self.assertEqual(self.adapter._helper['pid'], 13)

    def test_rollback_health_failure_needs_attention(self):
        self.after_start = lambda: self.fail_health.update({'a', 'b'})
        self.assert_outcome('needs_attention', ['stop', 'start', 'stop', 'start'])

    def test_initial_health_failure_does_not_stop(self):
        self.fail_health = {'a'}
        self.assert_outcome('rejected', [])

    def test_unknown_stop_does_not_swap(self):
        self.after_stop = lambda: setattr(self, 'absence_error', 'permission denied')
        self.assert_outcome('needs_attention', ['stop'])
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.old)

    def test_old_pid_still_alive_does_not_swap(self):
        self.old_alive = True
        self.assert_outcome('needs_attention', ['stop'])
        self.assertEqual(len(self.waits), 2)
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.old)

    def test_stop_timeout_bounded(self):
        self.no_stop = True
        self.assert_outcome('needs_attention', ['stop'])
        self.assertEqual(self.waits, [0.1, 0.1])

    def test_start_absent_timeout_cannot_prove_launched_process_gone(self):
        def fail_first():
            if self.mutations.count('start') == 1: self.running = False
        self.after_start = fail_first
        self.assert_outcome('needs_attention', ['stop', 'start'])
        self.assertIsNone(self.adapter.helper_stopped())
        self.assertEqual(len(self.waits), 2)

    def test_registered_unknown_start_does_not_swap_back(self):
        self.after_start = lambda: setattr(self, 'waiting', True)
        self.assert_outcome('needs_attention', ['stop', 'start'])
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.new)
        self.assertEqual(len(self.waits), 2)

    def test_bootstrap_error_after_launch_observes_pid_before_recovery(self):
        def fail_first():
            if self.mutations.count('start') == 1:
                raise subprocess.CalledProcessError(5, ['synthetic bootstrap'])
        self.after_start = fail_first
        self.assert_outcome('rolled_back', ['stop', 'start', 'stop', 'start'])

    def test_copy_failure_rejects_without_stop(self):
        def fail(*_): raise OSError('synthetic copy')
        self.assert_outcome('rejected', [], copier=fail)

    def test_candidate_rename_failure_restores_original(self):
        def move(source, target):
            if source.name == 'candidate.app': raise OSError('synthetic rename')
            transaction.move(source, target)
        self.assert_outcome('rolled_back', ['stop', 'start'], mover=move)
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.old)

    def drift_config(self):
        # Same parsed data, different bytes: frozen file identity must still reject.
        self.plist.write_bytes(plistlib.dumps(configuration(self.root), fmt=plistlib.FMT_BINARY))

    def test_configuration_hash_drift_before_stop_rejects(self):
        self.drift_config()
        self.assert_outcome('rejected', [])

    def test_configuration_drift_after_stop_halts(self):
        self.after_stop = self.drift_config
        self.assert_outcome('needs_attention', ['stop'])

    def test_loaded_path_drift_rejects(self):
        other = self.root / 'other.plist'; shutil.copyfile(self.plist, other)
        self.loaded_path = other
        self.assert_outcome('rejected', [])

    def test_missing_loaded_model_protection_rejects(self):
        self.arguments.pop()
        self.assert_outcome('rejected', [])

    def test_protected_start_time_drift_rejects(self):
        self.started = 'Thu Sep 17 10:00:01 2026'
        self.assert_outcome('rejected', [])

    def test_protected_pid_drift_after_start_halts(self):
        self.after_start = lambda: setattr(self, 'model_pid', 99)
        self.assert_outcome('needs_attention', ['stop', 'start'])

    def test_dirty_build_can_be_inspected_but_direct_stop_is_rejected(self):
        path = self.installed / 'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes()); info['CPABuildMetadata']['WorktreeDirty'] = True
        path.write_bytes(plistlib.dumps(info)); self.adapter = self.construct()
        self.assertTrue(self.adapter.preserves_resident_model())
        self.assertIs(self.adapter.helper_stopped(), False)
        with self.assertRaisesRegex(ValueError, 'dirty'): self.adapter.stop_helper()
        self.assertEqual(self.mutations, [])

    def test_direct_start_requires_confirmed_stop(self):
        with self.assertRaises(ValueError): self.adapter.start_helper()
        self.assertEqual(self.mutations, [])

    def test_missing_health_capability_cannot_stop(self):
        path = self.installed / 'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes()); info.pop('CPAHealthProtocolVersion')
        path.write_bytes(plistlib.dumps(info)); self.adapter = self.construct()
        with self.assertRaisesRegex(ValueError, 'capability'): self.adapter.stop_helper()
        self.assertEqual(self.mutations, [])

    def test_symlink_configuration_rejects_without_command(self):
        original = self.root / 'original.plist'; self.plist.rename(original); self.plist.symlink_to(original)
        with self.assertRaises(ValueError): self.construct()
        self.assertEqual(self.mutations, [])

    def test_health_result_must_bind_full_package_and_process(self):
        self.adapter.health_reader = lambda *a, **k: {'healthVerified': True, 'bundle': self.old}
        self.assertFalse(self.adapter.healthy_helper(self.old))


if __name__ == '__main__':
    unittest.main()
