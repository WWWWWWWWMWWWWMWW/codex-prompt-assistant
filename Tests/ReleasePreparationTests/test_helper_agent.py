import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools/Release'))
import helper_agent as agent


class HelperAgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['CPA_TEST_ROOT'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / '新用户 A & B $x `literal`'
        self.bundle = self.home / 'Applications/CodexPromptAssistantPOC.app'
        self.binary = self.bundle / agent.EXECUTABLE
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text('#!/bin/sh\nexit 99\n')
        self.binary.chmod(0o755)
        self.info_path = self.bundle / 'Contents/Info.plist'
        self.info = {'CFBundleIdentifier': agent.IDENTIFIER,
                     'CFBundleExecutable': self.binary.name, 'CPAUpdateLifecycleVersion': 1,
                     'CPABuildMetadata': {'SchemaVersion': 1, 'GitCommit': 'a' * 40, 'WorktreeDirty': True}}
        self.info_path.write_bytes(plistlib.dumps(self.info))
        self.expected = agent.sha256(self.binary)
        self.output = self.root / 'prepared'
        self.original = agent.tree_digest(self.bundle)
        self.launch_agent = self.home / 'Library/LaunchAgents' / (agent.LABEL + '.plist')
        self.launch_agent.parent.mkdir(parents=True)
        self.launch_agent.write_bytes(b'original configuration must remain')

    def prepare(self, **overrides):
        args = dict(user_home=self.home, output=self.output, expected_sha256=self.expected,
                    signature_check=lambda _: None)
        args.update(overrides)
        return agent.prepare(**args)

    def test_literal_paths_and_model_preservation_without_execution_or_installation(self):
        with patch('subprocess.Popen', side_effect=AssertionError('no process execution')):
            report = self.prepare()
        config = plistlib.loads((self.output / (agent.LABEL + '.plist')).read_bytes())
        self.assertEqual(config['ProgramArguments'], [str(self.binary), '--preserve-resident-model'])
        self.assertEqual(config['Label'], agent.LABEL)
        self.assertEqual(config['KeepAlive'], {'SuccessfulExit': False})
        self.assertEqual(config['LimitLoadToSessionType'], 'Aqua')
        self.assertEqual(config['ThrottleInterval'], 30)
        self.assertTrue(config['RunAtLoad'])
        self.assertFalse(report['installationReady'])
        self.assertTrue(report['bundle']['build']['WorktreeDirty'])
        self.assertEqual(report, json.loads((self.output / 'manifest.json').read_text()))
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.output / (agent.LABEL + '.plist')).stat().st_mode & 0o777, 0o600)
        self.assertEqual(agent.tree_digest(self.bundle), self.original)
        self.assertEqual(self.launch_agent.read_bytes(), b'original configuration must remain')

    def test_bad_hash_or_signature_rejected_before_output(self):
        for values in ({'expected_sha256': '0' * 64}, {'expected_sha256': 'invalid'},
                       {'signature_check': lambda _: (_ for _ in ()).throw(ValueError('signature failure'))}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.prepare(**values)
            self.assertFalse(self.output.exists())

    def test_wrong_identity_legacy_or_missing_preservation_rejected(self):
        invalid = [dict(self.info, CFBundleIdentifier='other'),
                   dict(self.info, CFBundleExecutable='other'),
                   dict(self.info, CPAUpdateLifecycleVersion=0),
                   dict(self.info, CPAUpdateLifecycleVersion=True),
                   dict(self.info, CPABuildMetadata={}),
                   dict(self.info, CPABuildMetadata=dict(self.info['CPABuildMetadata'], WorktreeDirty='no'))]
        for value in invalid:
            with self.subTest(value=value):
                self.info_path.write_bytes(plistlib.dumps(value))
                with self.assertRaises(ValueError): self.prepare()
                self.assertFalse(self.output.exists())

    def test_nonexecutable_and_bundle_links_rejected(self):
        self.binary.chmod(0o600)
        with self.assertRaises(ValueError): self.prepare()
        self.binary.chmod(0o755)
        actual = self.home / 'actual.app'; self.bundle.rename(actual); self.bundle.symlink_to(actual)
        with self.assertRaises(ValueError): self.prepare()
        self.assertFalse(self.output.exists())

    def test_existing_output_or_link_preserved(self):
        self.output.mkdir(); keep = self.output / 'keep'; keep.write_text('keep')
        with self.assertRaises(ValueError): self.prepare()
        self.assertEqual(keep.read_text(), 'keep')
        alias = self.root / 'alias'; alias.symlink_to(self.output)
        with self.assertRaises(ValueError): self.prepare(output=alias)
        self.assertEqual(keep.read_text(), 'keep')

    def test_output_inside_bundle_and_symlink_parent_rejected(self):
        with self.assertRaises(ValueError): self.prepare(output=self.bundle / 'nested')
        alias = self.root / 'alias'; alias.symlink_to(self.root)
        with self.assertRaises(ValueError): self.prepare(output=alias / 'new')
        self.assertEqual(agent.tree_digest(self.bundle), self.original)

    def test_bundle_change_during_validation_rejected(self):
        def change(_): self.binary.write_text('changed')
        with self.assertRaises(ValueError): self.prepare(signature_check=change)
        self.assertFalse(self.output.exists())

    def test_interrupted_manifest_does_not_publish_completion(self):
        with patch.object(agent, 'write_manifest', side_effect=OSError('fixture full disk')):
            with self.assertRaises(OSError): self.prepare()
        self.assertFalse((self.output / 'manifest.json').exists())
        self.assertEqual(agent.tree_digest(self.bundle), self.original)
        self.assertEqual(self.launch_agent.read_bytes(), b'original configuration must remain')

    def test_bundle_change_after_configuration_write_leaves_no_manifest(self):
        calls = 0
        def change_on_recheck(_):
            nonlocal calls
            calls += 1
            if calls == 2: self.binary.write_text('fixture replaced during preparation')
        with self.assertRaises(ValueError): self.prepare(signature_check=change_on_recheck)
        self.assertTrue((self.output / (agent.LABEL + '.plist')).exists())
        self.assertFalse((self.output / 'manifest.json').exists())
        self.assertEqual(self.launch_agent.read_bytes(), b'original configuration must remain')

    def test_launch_policy_matches_existing_template_except_direct_arguments(self):
        template = plistlib.loads((agent.REPOSITORY / 'Resources' / (agent.LABEL + '.plist')).read_bytes())
        config = agent.configuration(self.home)
        self.assertEqual({k:v for k,v in config.items() if k != 'ProgramArguments'},
                         {k:v for k,v in template.items() if k != 'ProgramArguments'})

    def test_different_users_have_distinct_targets_and_invalid_home_rejected(self):
        other = self.root / 'other'; other.mkdir()
        self.assertNotEqual(agent.configuration(self.home)['ProgramArguments'][0],
                            agent.configuration(other)['ProgramArguments'][0])
        for value in [Path('relative'), self.root / 'missing']:
            with self.assertRaises(ValueError): agent.configuration(value)

    def test_cli_output_name_cannot_escape_preparation_directory(self):
        for name in ['../escape', '/tmp/escape', 'a/b', '', 'x' * 81]:
            with self.assertRaises(ValueError): agent.preparation_output(name)

    def test_cli_signature_rejection_writes_no_completed_preparation(self):
        script = Path(agent.__file__)
        result = subprocess.run([sys.executable, str(script), '--home', str(self.home),
                                 '--expected-sha256', self.expected, '--name', 'fixture-invalid-signature'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no installation or service action', result.stderr)


if __name__ == '__main__':
    unittest.main()
