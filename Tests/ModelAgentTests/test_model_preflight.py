import json
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools/Release'))
import model_preflight as preflight


class ModelPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / '测试用户 with spaces'
        self.home.mkdir()
        self.base = self.home / 'Library/Application Support/CodexPromptAssistant'
        self.runtime = self.base / 'mlx-runtime'
        self.python = self.runtime / 'bin/python'
        self.entry = self.runtime / 'bin/mlx_lm.server'
        self.repo = self.base / 'model-cache/hub/models--mlx-community--Qwen3-4B-Instruct-2507-4bit'
        self.snapshot = self.repo / 'snapshots' / ('a' * 40)

    def ready_files(self):
        self.entry.parent.mkdir(parents=True)
        self.python.write_text('fixture: never execute'); self.python.chmod(0o700)
        self.entry.write_text('#!/bin/sh\n' + "'''exec' \"" + str(self.python) + '\" "$0" "$@"\n' + "' '''\n")
        self.entry.chmod(0o700)
        (self.repo / 'refs').mkdir(parents=True)
        (self.repo / 'refs/main').write_text('a' * 40)
        self.snapshot.mkdir(parents=True)
        for name in ('config.json', 'tokenizer_config.json', 'tokenizer.json'):
            (self.snapshot / name).write_text('{}')
        (self.snapshot / 'model.safetensors').write_bytes(b'fixture-not-real-weights')

    def blocked(self, key):
        return any(c['id'] == key and c['status'] == 'blocked' for c in preflight.inspect(self.home)['checks'])

    def test_empty_user_is_blocked_without_writes(self):
        result = preflight.inspect(self.home)
        self.assertFalse(result['artifactChecksPassed'])
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertFalse(result['runtimeVerified'])

    def test_files_pass_without_claiming_runtime_or_running_anything(self):
        self.ready_files()
        before = {str(p): (p.stat().st_size, p.stat().st_mtime_ns) for p in self.home.rglob('*')}
        with patch('subprocess.Popen', side_effect=AssertionError('no processes')), \
                patch('socket.socket', side_effect=AssertionError('no network')):
            result = preflight.inspect(self.home)
        self.assertTrue(result['artifactChecksPassed'])
        self.assertFalse(result['runtimeVerified'])
        self.assertEqual(result['weightFileCount'], 1)
        self.assertEqual(before, {str(p): (p.stat().st_size, p.stat().st_mtime_ns) for p in self.home.rglob('*')})

    def test_copied_launcher_referencing_old_existing_python_is_blocked(self):
        self.ready_files()
        old = self.home / 'old-python'; old.write_text('old'); old.chmod(0o700)
        self.entry.write_text('#!' + str(old) + '\n')
        self.assertTrue(self.blocked('launcher_interpreter'))

    def test_broken_interpreter_link_is_blocked(self):
        self.ready_files(); self.python.unlink(); self.python.symlink_to('/nonexistent/cpa-fixture/python')
        self.assertTrue(self.blocked('python'))

    def test_unknown_shell_wrapper_is_not_evaluated(self):
        self.ready_files(); self.entry.write_text('#!/bin/sh\nexec "$(echo python)"\n')
        self.assertTrue(self.blocked('launcher_interpreter'))

    def test_direct_shebang_supported(self):
        self.assertEqual(preflight.launcher_python('#!/tmp/user/bin/python3.12\n'), Path('/tmp/user/bin/python3.12'))
        self.assertIsNone(preflight.launcher_python('#!/usr/bin/env python3\n'))

    def test_missing_metadata_blocks(self):
        self.ready_files(); (self.snapshot / 'tokenizer.json').unlink()
        self.assertTrue(self.blocked('model_metadata'))

    def test_missing_empty_and_complete_shards(self):
        self.ready_files()
        index = self.snapshot / 'model.safetensors.index.json'
        index.write_text(json.dumps({'weight_map': {'a': 'part-1.safetensors', 'b': 'part-2.safetensors'}}))
        (self.snapshot / 'part-1.safetensors').write_bytes(b'one')
        self.assertTrue(self.blocked('weight_files'))
        (self.snapshot / 'part-2.safetensors').touch()
        self.assertTrue(self.blocked('weight_files'))
        (self.snapshot / 'part-2.safetensors').write_bytes(b'two')
        result = preflight.inspect(self.home)
        self.assertTrue(result['artifactChecksPassed']); self.assertEqual(result['weightBytes'], 6)

    def test_huggingface_blob_links_work_but_external_links_are_blocked(self):
        self.ready_files()
        weights = self.snapshot / 'model.safetensors'; weights.unlink()
        blob = self.repo / 'blobs/fixture'; blob.parent.mkdir(); blob.write_bytes(b'weights')
        weights.symlink_to('../../blobs/fixture')
        self.assertTrue(preflight.inspect(self.home)['artifactChecksPassed'])
        external = self.home / 'unrelated'; external.write_bytes(b'not this model')
        weights.unlink(); weights.symlink_to(external)
        self.assertTrue(self.blocked('weight_files'))

    def test_malformed_and_traversing_index_blocked(self):
        self.ready_files(); index = self.snapshot / 'model.safetensors.index.json'
        for value in ('not-json', '[]', '{}', json.dumps({'weight_map': {'a': '../../other.safetensors'}}),
                      json.dumps({'weight_map': {'a': None}})):
            index.write_text(value)
            self.assertFalse(preflight.inspect(self.home)['artifactChecksPassed'])

    def test_invalid_revision_not_followed(self):
        self.ready_files(); (self.repo / 'refs/main').write_text('../../elsewhere')
        self.assertTrue(self.blocked('cache_revision'))

    def test_oversized_metadata_is_bounded(self):
        self.ready_files()
        with patch.object(preflight, 'MAX_METADATA_BYTES', 16):
            result = preflight.inspect(self.home)
        self.assertFalse(result['artifactChecksPassed'])

    def test_fifo_metadata_is_not_opened(self):
        self.ready_files(); ref = self.repo / 'refs/main'; ref.unlink(); os.mkfifo(ref)
        self.assertTrue(self.blocked('cache_revision'))

    def test_cli_reports_blocked_and_success_but_never_runtime_ready(self):
        args = ['model_preflight.py', '--home', str(self.home), '--json']
        with patch('sys.argv', args), patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(preflight.main(), 2)
        result = json.loads(output.getvalue())
        self.assertFalse(result['artifactChecksPassed'])
        self.assertTrue(all(c['message'] == '检查未通过。' for c in result['checks'] if c['status'] == 'blocked'))
        self.ready_files()
        with patch('sys.argv', args), patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(preflight.main(), 0)
        self.assertFalse(json.loads(output.getvalue())['runtimeVerified'])


if __name__ == '__main__':
    unittest.main()
