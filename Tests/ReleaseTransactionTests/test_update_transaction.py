import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[2] / 'Tools/Release'
sys.path.insert(0, str(TOOLS))
import prepare_update as preparation
import update_transaction as transaction


class Services:
    """Synchronous, synthetic service boundary; never launches any processes."""
    def __init__(self, current):
        self.current = current
        self.protected = ('codex:42:start1', 'model:51:start2')
        self.stopped = False
        self.events = []
        self.fail_start = 0
        self.fail_stop = 0
        self.model_missing = False
        self.on_start = None
        self.model_preservation = True

    def preserves_resident_model(self):
        # Real adapter must verify the current helper and future launch parameters,
        # not just whether the bundle understands the option.
        return self.model_preservation

    def protected_identity(self):
        if self.model_missing:
            raise RuntimeError('synthetic model missing')
        return self.protected

    def helper_stopped(self):
        return self.stopped

    def stop_helper(self):
        self.events.append('stop')
        if self.fail_stop:
            self.fail_stop -= 1
            self.stopped = None  # command outcome is unknown, not confirmed stopped
            raise RuntimeError('synthetic stop uncertain')
        self.stopped = True

    def start_helper(self):
        self.events.append('start')
        self.stopped = False
        if self.on_start:
            self.on_start()
        if self.fail_start:
            self.fail_start -= 1
            raise RuntimeError('synthetic startup timeout after possible launch')

    def healthy_helper(self, expected):
        # Real adapter must use a running identity/health receipt, not this fixture read.
        return self.stopped is False and preparation.inspect(self.current, lambda _: None) == expected


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['CPA_TEST_ROOT'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.installed = self.bundle('installed.app', 'a' * 40)
        self.candidate = self.bundle('candidate.app', 'b' * 40)
        self.old = preparation.inspect(self.installed, lambda _: None)
        self.new = preparation.inspect(self.candidate, lambda _: None)
        self.prepared = self.root / 'prepared'
        preparation.prepare(self.candidate, self.installed, self.prepared, 'b' * 40,
                            self.old['executableSHA256'], lambda _: None, shutil.copytree)
        self.services = Services(self.installed)

    def bundle(self, name, commit):
        bundle = self.root / name
        executable = bundle / preparation.EXECUTABLE
        executable.parent.mkdir(parents=True)
        executable.write_text('synthetic non-executable content ' + commit)
        executable.chmod(0o755)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': preparation.IDENTIFIER,
            'CFBundleExecutable': Path(preparation.EXECUTABLE).name,
            'CPAUpdateLifecycleVersion': 1,
            'CPABuildMetadata': {'SchemaVersion': 1, 'GitCommit': commit, 'WorktreeDirty': False}}))
        return bundle

    def run_update(self, **options):
        return transaction.update(self.prepared, self.installed, self.services,
                                  signature_check=lambda _: None, copier=shutil.copytree, **options)

    def assert_old_installed(self):
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.old)

    def test_success_preserves_original_and_records_all_steps(self):
        result = self.run_update()
        self.assertEqual(result['outcome'], 'updated')
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.new)
        self.assertEqual(preparation.inspect(Path(result['directory']) / 'original.app', lambda _: None), self.old)
        self.assertEqual(self.services.events, ['stop', 'start'])
        journal = json.loads((Path(result['directory']) / 'journal.json').read_text())
        self.assertEqual(journal['outcome'], 'updated')
        self.assertEqual(self.services.protected, ('codex:42:start1', 'model:51:start2'))

    def test_incapable_candidate_or_rollback_rejects_before_service_actions(self):
        # Build a consistent preparation, so rejection cannot come from a stale hash.
        for role in ('candidate', 'rollback'):
            for value in (None, 0, 2, True, '1'):
                with self.subTest(role=role, value=value), tempfile.TemporaryDirectory(
                        dir=os.environ['CPA_TEST_ROOT']) as folder:
                    root = Path(folder).resolve()
                    candidate, installed = root / 'candidate.app', root / 'installed.app'
                    shutil.copytree(self.candidate, candidate); shutil.copytree(self.installed, installed)
                    path = (candidate if role == 'candidate' else installed) / 'Contents/Info.plist'
                    info = plistlib.loads(path.read_bytes())
                    if value is None: info.pop('CPAUpdateLifecycleVersion')
                    else: info['CPAUpdateLifecycleVersion'] = value
                    path.write_bytes(plistlib.dumps(info))
                    old = preparation.inspect(installed, lambda _: None)
                    prepared = root / 'prepared'
                    preparation.prepare(candidate, installed, prepared, 'b' * 40,
                        old['executableSHA256'], lambda _: None, shutil.copytree)
                    services = Services(installed)
                    result = transaction.update(prepared, installed, services,
                        signature_check=lambda _: None, copier=shutil.copytree)
                    self.assertEqual(result['outcome'], 'rejected')
                    self.assertEqual(services.events, [])
                    self.assertEqual(preparation.inspect(installed, lambda _: None), old)

    def test_missing_false_or_unknown_adapter_protection_rejects_before_stop(self):
        for value in (False, None, 1, 'true'):
            with self.subTest(value=value):
                self.services.model_preservation = value
                self.assertEqual(self.run_update()['outcome'], 'rejected')
                self.assertEqual(self.services.events, [])
                self.assert_old_installed()
        self.services.preserves_resident_model = None
        self.assertEqual(self.run_update()['outcome'], 'rejected')
        self.assertEqual(self.services.events, [])

    def test_protection_removed_during_staging_rejects_without_stopping(self):
        def copy_then_change(source, destination):
            shutil.copytree(source, destination)
            self.services.model_preservation = False
        result = transaction.update(self.prepared, self.installed, self.services,
            signature_check=lambda _: None, copier=copy_then_change)
        self.assertEqual(result['outcome'], 'rejected')
        self.assertEqual(self.services.events, [])
        self.assert_old_installed()

    def test_protection_removed_after_stop_never_installs_or_restarts(self):
        original = self.services.stop_helper
        def stop_then_change():
            original(); self.services.model_preservation = False
        self.services.stop_helper = stop_then_change
        self.assertEqual(self.run_update()['outcome'], 'needs_attention')
        self.assertEqual(self.services.events, ['stop'])
        self.assert_old_installed()

    def test_protection_removed_on_start_blocks_automatic_rollback(self):
        self.services.on_start = lambda: setattr(self.services, 'model_preservation', False)
        self.assertEqual(self.run_update()['outcome'], 'needs_attention')
        self.assertEqual(self.services.events, ['stop', 'start'])

    def test_missing_model_and_stale_installed_identity_reject_before_stop(self):
        self.services.model_missing = True
        self.assertEqual(self.run_update()['outcome'], 'rejected')
        self.services.model_missing = False
        (self.installed / preparation.EXECUTABLE).write_text('synthetic changed installation')
        self.assertEqual(self.run_update()['outcome'], 'rejected')
        self.assertEqual(self.services.events, [])

    def test_stage_copy_failure_never_stops_or_changes_installed(self):
        def fail_copy(source, destination):
            raise OSError('synthetic disk full')
        result = transaction.update(self.prepared, self.installed, self.services,
                                    signature_check=lambda _: None, copier=fail_copy)
        self.assertEqual(result['outcome'], 'rejected')
        self.assertEqual(self.services.events, [])
        self.assert_old_installed()

    def test_uncertain_stop_does_not_exchange_or_restart(self):
        self.services.fail_stop = 1
        result = self.run_update()
        self.assertEqual(result['outcome'], 'needs_attention')
        self.assertEqual(self.services.events, ['stop'])
        self.assert_old_installed()

    def test_start_failure_restores_exact_old_package_once(self):
        self.services.fail_start = 1
        result = self.run_update()
        self.assertEqual(result['outcome'], 'rolled_back')
        self.assertEqual(self.services.events, ['stop', 'start', 'stop', 'start'])
        self.assert_old_installed()
        self.assertEqual(preparation.inspect(Path(result['directory']) / 'failed.app', lambda _: None), self.new)

    def test_rollback_start_failure_is_not_reported_as_recovered(self):
        self.services.fail_start = 2
        result = self.run_update()
        self.assertEqual(result['outcome'], 'needs_attention')
        self.assertEqual(self.services.events.count('start'), 2)
        self.assert_old_installed()

    def test_uncertain_candidate_stop_never_overwrites_possibly_running_package(self):
        self.services.fail_start = 1
        self.services.on_start = lambda: setattr(self.services, 'fail_stop', 1)
        result = self.run_update()
        self.assertEqual(result['outcome'], 'needs_attention')
        self.assertEqual(self.services.events.count('start'), 1)
        self.assertEqual(preparation.inspect(self.installed, lambda _: None), self.new)
        self.assertEqual(preparation.inspect(Path(result['directory']) / 'original.app', lambda _: None), self.old)

    def test_protected_process_change_stops_automatic_recovery(self):
        self.services.on_start = lambda: setattr(self.services, 'protected', ('codex:43:new', 'model:51:start2'))
        result = self.run_update()
        self.assertEqual(result['outcome'], 'needs_attention')
        self.assertEqual(self.services.events, ['stop', 'start'])

    def test_exchange_and_restore_failures_preserve_recovery_evidence(self):
        for failure in (1, 2, 3, 4):
            with self.subTest(failure=failure):
                # Independent directory per fault; incomplete transactions are intentionally blocking.
                with tempfile.TemporaryDirectory(dir=os.environ['CPA_TEST_ROOT']) as directory:
                    installed = Path(directory).resolve() / 'installed.app'
                    shutil.copytree(self.installed, installed)
                    services = Services(installed)
                    services.fail_start = 1
                    calls = 0
                    def rename(source, destination):
                        nonlocal calls
                        calls += 1
                        if calls == failure:
                            raise OSError('synthetic rename failure')
                        source.rename(destination)
                    result = transaction.update(self.prepared, installed, services,
                        signature_check=lambda _: None, copier=shutil.copytree, mover=rename)
                    self.assertIn(result['outcome'], ('rolled_back', 'needs_attention'))
                    self.assertTrue(installed.exists() or (Path(result['directory']) / 'original.app').exists())
                    self.assertLessEqual(services.events.count('start'), 2)

    def test_previous_incomplete_transaction_blocks_retry(self):
        self.services.fail_stop = 1
        self.assertEqual(self.run_update()['outcome'], 'needs_attention')
        previous = list(self.services.events)
        self.assertEqual(self.run_update()['outcome'], 'rejected')
        self.assertEqual(self.services.events, previous)

    def test_failed_exchange_restores_old_without_attempting_new_start(self):
        for fail_at in (1, 2):
            with tempfile.TemporaryDirectory(dir=os.environ['CPA_TEST_ROOT']) as directory:
                installed = Path(directory).resolve() / 'installed.app'
                shutil.copytree(self.installed, installed)
                services = Services(installed)
                calls = 0
                def rename(source, destination):
                    nonlocal calls
                    calls += 1
                    if calls == fail_at:
                        raise OSError('synthetic exchange failure')
                    transaction.move(source, destination)
                result = transaction.update(self.prepared, installed, services,
                    signature_check=lambda _: None, copier=shutil.copytree, mover=rename)
                self.assertEqual(result['outcome'], 'rolled_back')
                self.assertEqual(services.events, ['stop', 'start'])
                self.assertEqual(preparation.inspect(installed, lambda _: None), self.old)

    def test_missing_health_receipt_does_not_report_success(self):
        original = self.services.healthy_helper
        self.services.healthy_helper = lambda expected: expected == self.old and original(expected)
        self.assertEqual(self.run_update()['outcome'], 'rolled_back')
        self.assert_old_installed()

    def test_old_running_identity_mismatch_rejects_before_stop(self):
        self.services.healthy_helper = lambda _: False
        self.assertEqual(self.run_update()['outcome'], 'rejected')
        self.assertEqual(self.services.events, [])

    def test_interrupted_stop_never_triggers_automatic_restart(self):
        def interrupted():
            self.services.events.append('stop')
            self.services.stopped = True
            raise KeyboardInterrupt()
        self.services.stop_helper = interrupted
        self.assertEqual(self.run_update()['outcome'], 'needs_attention')
        self.assertEqual(self.services.events, ['stop'])
        self.assert_old_installed()

    def test_journal_failure_before_stop_prevents_service_mutation(self):
        with patch.object(transaction, 'write_journal', side_effect=OSError('synthetic write failure')):
            result = self.run_update()
        self.assertEqual(result['outcome'], 'needs_attention')
        self.assertEqual(self.services.events, [])
        self.assert_old_installed()

    def test_concurrent_transaction_rejects_without_second_stop(self):
        original = self.services.stop_helper
        nested = []
        def stop():
            nested.append(self.run_update())
            original()
        self.services.stop_helper = stop
        self.assertEqual(self.run_update()['outcome'], 'updated')
        self.assertEqual(nested[0]['outcome'], 'rejected')
        self.assertEqual(self.services.events, ['stop', 'start'])


if __name__ == '__main__':
    unittest.main()
