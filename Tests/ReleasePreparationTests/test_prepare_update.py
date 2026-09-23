import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "Tools/Release/prepare_update.py"
spec = importlib.util.spec_from_file_location("prepare_update", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ["CPA_TEST_ROOT"])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.candidate = self.bundle("candidate.app", "a" * 40)
        self.installed = self.bundle("installed.app", "b" * 40)
        self.output = self.root / "prepared"
        self.old_hash = release.sha256(self.installed / release.EXECUTABLE)
        self.source_bytes = self.snapshot_sources()

    def bundle(self, name, commit):
        bundle = self.root / name
        executable = bundle / release.EXECUTABLE
        executable.parent.mkdir(parents=True)
        # Executing a fixture would leave a marker; preparation must only inspect it.
        executable.write_text("#!/bin/sh\ntouch '" + str(self.root / "LAUNCHED") + "'\n# " + commit)
        executable.chmod(0o755)
        info = {"CFBundleIdentifier": release.IDENTIFIER,
                "CFBundleExecutable": Path(release.EXECUTABLE).name,
                "CPABuildMetadata": {"SchemaVersion": 1, "GitCommit": commit, "WorktreeDirty": False}}
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        return bundle

    def snapshot_sources(self):
        return [release.tree_digest(path) for path in (self.candidate, self.installed)]

    def prepare(self, **overrides):
        arguments = dict(candidate=self.candidate, installed=self.installed, output=self.output,
                         expected_commit="a" * 40, expected_installed_sha256=self.old_hash,
                         signature_check=lambda _: None, copier=shutil.copytree)
        arguments.update(overrides)
        return release.prepare(**arguments)

    def assert_sources_preserved(self):
        self.assertEqual(self.snapshot_sources(), self.source_bytes)
        self.assertFalse((self.root / "LAUNCHED").exists())

    def test_success_keeps_independent_verified_rollback_after_sources_are_unavailable(self):
        manifest = self.prepare()
        self.assert_sources_preserved()
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(manifest["bundles"]["rollback"]["executableSHA256"], self.old_hash)
        self.candidate.rename(self.root / "unavailable-candidate")
        self.installed.rename(self.root / "unavailable-installed")
        self.assertEqual(release.verify_preparation(self.output, lambda _: None), manifest)
        # This copy is the old package, never the candidate rebuilt from current HEAD.
        self.assertNotEqual(release.sha256(self.output / "candidate.app" / release.EXECUTABLE), self.old_hash)
        self.assertEqual(release.sha256(self.output / "rollback.app" / release.EXECUTABLE), self.old_hash)
        self.assertFalse((self.root / "LAUNCHED").exists())

    def test_copy_failure_for_either_bundle_leaves_no_ready_manifest(self):
        for role in ("candidate", "rollback"):
            with self.subTest(role=role):
                output = self.root / role
                def fail_copy(source, destination):
                    shutil.copytree(source, destination)
                    if destination.name == release.ROLES[role]:
                        raise OSError("synthetic disk-full after partial copy")
                with self.assertRaises(OSError):
                    self.prepare(output=output, copier=fail_copy)
                self.assertFalse((output / "manifest.json").exists())
                with self.assertRaises(FileNotFoundError):
                    release.verify_preparation(output, lambda _: None)
                self.assert_sources_preserved()

    def test_signature_failure_at_each_stage_never_marks_ready(self):
        for failure in range(1, 7):  # sources, copies, then source revalidation
            with self.subTest(failure=failure):
                calls = 0
                output = self.root / ("signature-" + str(failure))
                def check(_):
                    nonlocal calls
                    calls += 1
                    if calls == failure:
                        raise ValueError("synthetic invalid signature")
                with self.assertRaises(ValueError):
                    self.prepare(output=output, signature_check=check)
                self.assertFalse((output / "manifest.json").exists())
                self.assert_sources_preserved()

    def test_wrong_expected_identities_are_rejected_before_copying(self):
        for options in ({"expected_commit": "c" * 40}, {"expected_installed_sha256": "0" * 64}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.prepare(**options)
            self.assertFalse(self.output.exists())
        self.assert_sources_preserved()

    def test_dirty_legacy_wrong_identifier_and_malformed_metadata_are_rejected(self):
        path = self.candidate / "Contents/Info.plist"
        original = plistlib.loads(path.read_bytes())
        invalid = [{**original, "CPABuildMetadata": {**original["CPABuildMetadata"], "WorktreeDirty": True}},
                   {key: value for key, value in original.items() if key != "CPABuildMetadata"},
                   {**original, "CFBundleIdentifier": "invalid.fixture"},
                   {**original, "CPABuildMetadata": "invalid"}]
        for info in invalid:
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                self.prepare()
            self.assertFalse(self.output.exists())

    def test_source_change_during_copy_invalidates_preparation(self):
        def copy_then_change(source, destination):
            shutil.copytree(source, destination)
            if source == self.installed.resolve():
                (self.candidate / release.EXECUTABLE).write_text("synthetic concurrent build")
        with self.assertRaisesRegex(ValueError, "source changed"):
            self.prepare(copier=copy_then_change)
        self.assertFalse((self.output / "manifest.json").exists())
        self.assertEqual(release.sha256(self.installed / release.EXECUTABLE), self.old_hash)

    def test_copy_corruption_is_rejected(self):
        def corrupt(source, destination):
            shutil.copytree(source, destination)
            (destination / release.EXECUTABLE).write_text("synthetic truncated executable")
        with self.assertRaisesRegex(ValueError, "copied bundle mismatch"):
            self.prepare(copier=corrupt)
        self.assertFalse((self.output / "manifest.json").exists())
        self.assert_sources_preserved()

    def test_manifest_failure_leaves_incomplete_copies_and_no_ready_marker(self):
        with patch.object(release, "write_manifest", side_effect=OSError("synthetic write failure")):
            with self.assertRaises(OSError):
                self.prepare()
        self.assertFalse((self.output / "manifest.json").exists())
        self.assertTrue((self.output / "rollback.app").exists())
        self.assert_sources_preserved()

    def test_interrupt_during_copy_cannot_be_mistaken_for_ready_artifacts(self):
        def interrupted(source, destination):
            shutil.copytree(source, destination)
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            self.prepare(copier=interrupted)
        self.assertFalse((self.output / "manifest.json").exists())
        with self.assertRaises(FileNotFoundError):
            release.verify_preparation(self.output, lambda _: None)
        self.assert_sources_preserved()

    def test_change_during_signature_verification_is_rejected(self):
        def changed(bundle):
            (bundle / release.EXECUTABLE).write_text("synthetic change during verification")
        with self.assertRaisesRegex(ValueError, "changed during inspection"):
            self.prepare(signature_check=changed)
        self.assertFalse(self.output.exists())
        self.assertEqual(release.sha256(self.installed / release.EXECUTABLE), self.old_hash)

    def test_retry_cannot_overwrite_existing_preparation(self):
        manifest = self.prepare()
        with self.assertRaisesRegex(ValueError, "output already exists"):
            self.prepare()
        self.assertEqual(release.verify_preparation(self.output, lambda _: None), manifest)
        self.assert_sources_preserved()

    def test_nested_output_and_cli_path_escape_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "overlap"):
            self.prepare(output=self.installed / "nested")
        for name in ("../escape", "/Applications/replace", "..", "a/b"):
            with self.assertRaisesRegex(ValueError, "invalid preparation name"):
                release.preparation_output(name)
        self.assert_sources_preserved()

    def test_symlink_content_is_rejected_without_following_it(self):
        (self.candidate / "Contents/link").symlink_to(self.installed)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_reverification_catches_bytes_permissions_and_missing_manifest_record(self):
        for damage in ("bytes", "permissions", "manifest"):
            output = self.root / damage
            self.prepare(output=output)
            executable = output / "rollback.app" / release.EXECUTABLE
            if damage == "bytes":
                executable.write_text("synthetic tampering")
            elif damage == "permissions":
                executable.chmod(0o644)
            else:
                path = output / "manifest.json"
                manifest = json.loads(path.read_text())
                del manifest["bundles"]["rollback"]
                path.write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                release.verify_preparation(output, lambda _: None)
        self.assert_sources_preserved()

    def test_default_verifier_rejects_unsigned_fixture_without_executing_it(self):
        with self.assertRaises(subprocess.CalledProcessError):
            release.inspect(self.candidate)
        self.assertFalse((self.root / "LAUNCHED").exists())

    def test_real_ditto_preserves_fixture_bytes_and_permissions(self):
        self.prepare(copier=release.copy_bundle)
        self.assertEqual(release.tree_digest(self.output / "rollback.app"), release.tree_digest(self.installed))
        self.assert_sources_preserved()

    def test_cli_verify_incomplete_preparation_returns_failure(self):
        self.output.mkdir()
        result = subprocess.run([sys.executable, str(SCRIPT), "verify", str(self.output)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no installation or service action", result.stderr)


if __name__ == "__main__":
    unittest.main()
