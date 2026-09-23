import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / 'Tools/BuildMetadata/build_metadata.py'
spec = importlib.util.spec_from_file_location('build_metadata', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ['Resources', 'Sources/RemoteCompletionCore']:
            (self.root / directory).mkdir(parents=True)
        self.info = self.root / 'Resources/Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.2.0', 'CFBundleVersion': '2',
            'CFBundleIdentifier': 'local.codex.prompt-assistant-poc'}))
        (self.root / 'Sources/RemoteCompletionCore/CompletionIdentity.h').write_text(
            '#define CPA_PROMPT_VERSION "prefix-v1"\n#define CPA_DEFAULT_LOCAL_MODEL "fixture/model"\n')
        self.protocol = self.root / 'Sources/RemoteCompletionCore/RemoteCompletionProtocol.m'
        self.protocol.write_text('synthetic prompt source')
        (self.root / '.gitignore').write_text('.build/\n')
        self.output = self.root / '.build/generated'
        self.git('init', '-q')
        self.git('add', '.')
        self.commit()

    def git(self, *args):
        return module.git(self.root, *args)

    def commit(self):
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')

    def test_clean_repeat_preserves_mtime_and_bundle_identity(self):
        first = module.generate(self.root, self.output)
        header = self.output / 'CPABuildMetadata.h'
        old_mtime = header.stat().st_mtime_ns
        self.assertFalse(first['WorktreeDirty'])
        self.assertEqual(first, module.generate(self.root, self.output))
        self.assertEqual(old_mtime, header.stat().st_mtime_ns)
        info = plistlib.loads((self.output / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'local.codex.prompt-assistant-poc')
        self.assertEqual(info['CPABuildMetadata'], first)
        self.assertNotIn('CPABuildMetadata', plistlib.loads(self.info.read_bytes()))
        line = next(x for x in header.read_text().splitlines() if x.startswith('#define CPA_BUILD_METADATA_JSON '))
        self.assertEqual(json.loads(json.loads(line.split(' ', 2)[2])), first)

    def test_dirty_and_new_head_refresh_without_prompt_change(self):
        clean = module.generate(self.root, self.output)
        (self.root / 'note.md').write_text('synthetic untracked change')
        self.assertTrue(module.generate(self.root, self.output)['WorktreeDirty'])
        self.git('add', 'note.md')
        self.assertTrue(module.generate(self.root, self.output)['WorktreeDirty'])
        self.commit()
        committed = module.generate(self.root, self.output)
        self.assertFalse(committed['WorktreeDirty'])
        self.assertNotEqual(committed['GitCommit'], clean['GitCommit'])
        self.assertEqual(committed['PromptSourceSHA256'], clean['PromptSourceSHA256'])

    def test_prompt_changes_are_identifiable(self):
        clean = module.generate(self.root, self.output)
        self.protocol.write_text('changed synthetic prompt source')
        dirty = module.generate(self.root, self.output)
        self.assertTrue(dirty['WorktreeDirty'])
        self.assertNotEqual(clean['PromptSourceSHA256'], dirty['PromptSourceSHA256'])

    def test_missing_config_fails_without_overwriting_previous_artifacts(self):
        module.generate(self.root, self.output)
        original = (self.output / 'Info.plist').read_bytes()
        (self.root / 'Sources/RemoteCompletionCore/CompletionIdentity.h').write_text('invalid')
        with self.assertRaises(ValueError):
            module.generate(self.root, self.output)
        self.assertEqual(original, (self.output / 'Info.plist').read_bytes())

    def test_inspection_never_launches_legacy_executable(self):
        bundle = self.root / 'legacy.app'
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(self.info.read_bytes())
        # Deliberately not executable: inspection must only read bytes.
        (bundle / 'Contents/MacOS/CodexPromptAssistantPOC').write_bytes(b'legacy fixture')
        self.assertIn('unknown', module.inspect_bundle(bundle)['BuildMetadata']['GitCommit'])


if __name__ == '__main__':
    unittest.main()
