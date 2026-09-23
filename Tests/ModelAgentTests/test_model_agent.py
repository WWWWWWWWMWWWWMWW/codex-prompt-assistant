import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('model_agent', ROOT / 'Tools/Release/model_agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class ModelAgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / '不同用户 A & B $x `literal`'
        self.home.mkdir()
        self.output = self.home / 'Library/LaunchAgents' / (agent.LABEL + '.plist')

    def runtime(self):
        runtime = self.home / 'Library/Application Support/CodexPromptAssistant/mlx-runtime/bin/mlx_lm.server'
        runtime.parent.mkdir(parents=True)
        runtime.write_text('#!/bin/sh\nexit 99\n')
        runtime.chmod(0o700)
        return runtime

    def test_paths_are_literal_user_paths_and_settings_preserved(self):
        runtime = self.runtime()
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('must not launch')):
            self.assertEqual(agent.prepare(self.home, self.output), 'prepared')
        config = plistlib.loads(self.output.read_bytes())
        self.assertEqual(config['ProgramArguments'][0], str(runtime))
        self.assertEqual(config['EnvironmentVariables']['HF_HOME'], str(runtime.parents[2] / 'model-cache'))
        self.assertEqual(config['StandardOutPath'], str(runtime.parents[2] / 'local-model.log'))
        self.assertEqual(config['StandardErrorPath'], config['StandardOutPath'])
        self.assertEqual(config['Label'], agent.LABEL)
        self.assertEqual(config['ProgramArguments'][1:], plistlib.loads(agent.TEMPLATE.read_bytes())['ProgramArguments'][1:])
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(agent.HOME_TOKEN, self.output.read_text())

    def test_missing_runtime_writes_nothing(self):
        with self.assertRaisesRegex(ValueError, '运行程序'):
            agent.prepare(self.home, self.output)
        self.assertFalse((self.home / 'Library').exists())

    def test_nonexecutable_runtime_rejected(self):
        self.runtime().chmod(0o600)
        with self.assertRaises(ValueError):
            agent.prepare(self.home, self.output)
        self.assertFalse(self.output.parent.exists())

    def test_existing_equal_configuration_untouched(self):
        self.runtime(); agent.prepare(self.home, self.output)
        before = (self.output.stat().st_ino, self.output.stat().st_mtime_ns, self.output.read_bytes())
        self.assertEqual(agent.prepare(self.home, self.output), 'unchanged')
        self.assertEqual(before, (self.output.stat().st_ino, self.output.stat().st_mtime_ns, self.output.read_bytes()))

    def test_custom_and_invalid_configuration_preserved(self):
        self.runtime(); self.output.parent.mkdir(parents=True)
        for content in [b'custom-invalid', plistlib.dumps({'Label': agent.LABEL, 'custom': True})]:
            self.output.write_bytes(content)
            with self.assertRaisesRegex(ValueError, '已有不同'):
                agent.prepare(self.home, self.output)
            self.assertEqual(self.output.read_bytes(), content)

    def test_symlink_not_overwritten(self):
        self.runtime(); self.output.parent.mkdir(parents=True)
        target = self.home / 'untouched'; target.write_text('keep')
        self.output.symlink_to(target)
        with self.assertRaisesRegex(ValueError, '符号链接'):
            agent.prepare(self.home, self.output)
        self.assertEqual(target.read_text(), 'keep')

    def test_interrupted_publish_leaves_no_partial_file(self):
        self.runtime()
        with patch.object(agent.os, 'link', side_effect=OSError('fixture disk failure')):
            with self.assertRaises(OSError):
                agent.prepare(self.home, self.output)
        self.assertEqual(list(self.output.parent.iterdir()), [])

    def test_concurrent_writer_is_preserved(self):
        self.runtime()
        def race(source, target):
            Path(target).write_bytes(b'other writer')
            raise FileExistsError('race')
        with patch.object(agent.os, 'link', side_effect=race):
            with self.assertRaises(FileExistsError):
                agent.prepare(self.home, self.output)
        self.assertEqual(self.output.read_bytes(), b'other writer')

    def test_relative_home_rejected(self):
        with self.assertRaises(ValueError):
            agent.configuration(Path('relative'))

    def test_cli_missing_runtime_fails_without_writes(self):
        result = subprocess.run(['python3', str(ROOT / 'Tools/Release/model_agent.py'), 'prepare',
            '--home', str(self.home), '--output', str(self.output)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('未写入启动配置', result.stderr)
        self.assertFalse(self.output.parent.exists())

    def test_install_uses_current_user_and_preserves_custom_configuration(self):
        self.runtime()
        with patch.object(agent.Path, 'home', return_value=self.home), \
                patch('sys.argv', ['model_agent.py', 'install']), patch('sys.stdout', new_callable=io.StringIO):
            agent.main()
            self.assertTrue(self.output.exists())
            self.output.write_bytes(b'keep custom configuration')
            with patch('sys.stderr', new_callable=io.StringIO), self.assertRaises(SystemExit) as error:
                agent.main()
            self.assertEqual(error.exception.code, 1)
            self.assertEqual(self.output.read_bytes(), b'keep custom configuration')

    def test_different_users_do_not_share_runtime_cache_or_log_paths(self):
        other = Path(self.temp.name) / 'second-user'; other.mkdir()
        first, second = agent.configuration(self.home), agent.configuration(other)
        self.assertNotEqual(first['ProgramArguments'][0], second['ProgramArguments'][0])
        self.assertNotEqual(first['EnvironmentVariables']['HF_HOME'], second['EnvironmentVariables']['HF_HOME'])
        self.assertNotEqual(first['StandardOutPath'], second['StandardOutPath'])
        self.assertTrue(second['ProgramArguments'][0].startswith(str(other) + '/'))


if __name__ == '__main__':
    unittest.main()
