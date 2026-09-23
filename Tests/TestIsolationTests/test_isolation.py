import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'Tools/Testing/run_isolated.py'

class TestIsolation(unittest.TestCase):
    def test_public_make_target_uses_runner(self):
        result = subprocess.run(['make', '-n', 'test'], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('Tools/Testing/run_isolated.py', result.stdout)

    def test_internal_suites_never_install_or_use_production_rebuild(self):
        for target in ('test-run', 'data-core-test-run', 'remote-completion-test-run',
                       'release-preparation-test-run', 'release-transaction-test-run'):
            result = subprocess.run(['make', '-n', target], cwd=ROOT,
                env=dict(os.environ, CPA_TEST_ROOT='/tmp/cpa-dry-run'),
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('overriding commands', result.stderr)
            for forbidden in ('/usr/bin/ditto', 'install -m', 'launchctl ', '--sign '):
                self.assertNotIn(forbidden, result.stdout)
            self.assertNotIn('Sources/CodexDataCore/KeychainStore.m', result.stdout)
            if target == 'data-core-test-run':
                self.assertIn('-o .build/tests/CodexDataRebuild', result.stdout)
                self.assertNotIn('-o build/CodexDataRebuild', result.stdout)

    def test_sandbox_blocks_installation_write(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('isolation_runner', RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            target = home / 'Applications/fixture.app'
            target.parent.mkdir()
            target.write_text('unchanged')
            result = subprocess.run(['/usr/bin/sandbox-exec', '-p', runner.sandbox_profile(home),
                sys.executable, '-c', 'import pathlib,sys;pathlib.Path(sys.argv[1]).write_text("changed")',
                str(target)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), 'unchanged')

    def test_success_and_failure_clean_synthetic_credentials(self):
        for code in (0, 7):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                report = Path(directory) / 'report.json'
                child = """import os,json,pathlib,sys
root=pathlib.Path(os.environ['CPA_TEST_ROOT'])
(root/'synthetic-key').write_bytes(b'fixture')
pathlib.Path(sys.argv[1]).write_text(json.dumps({'root':str(root),'mode':root.stat().st_mode & 0o777}))
sys.exit(int(sys.argv[2]))
"""
                result = subprocess.run([sys.executable, str(RUNNER), sys.executable,
                    '-c', child, str(report), str(code)], cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(result.returncode, code, result.stderr)
                data = json.loads(report.read_text())
                self.assertEqual(data['mode'], 0o700)
                self.assertFalse(Path(data['root']).exists())

    def test_runner_blocks_network_and_service_commands(self):
        for child in (
            'import socket; socket.create_connection(("127.0.0.1", 1), timeout=1)',
            'import subprocess; subprocess.run(["/bin/launchctl", "help"], check=True)',
        ):
            script = 'try:\n ' + child + '\nexcept PermissionError:\n raise SystemExit(0)\nraise SystemExit(9)'
            result = subprocess.run([sys.executable, str(RUNNER), sys.executable,
                '-c', script], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_termination_cleans_run_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'root.txt'
            child = "import os,pathlib,sys,time;pathlib.Path(sys.argv[1]).write_text(os.environ['CPA_TEST_ROOT']);time.sleep(30)"
            process = subprocess.Popen([sys.executable, str(RUNNER), sys.executable,
                '-c', child, str(report)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not report.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(report.exists())
                root = Path(report.read_text())
                process.send_signal(signal.SIGTERM)
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 128 + signal.SIGTERM)
                self.assertFalse(root.exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stderr.close()

if __name__ == '__main__':
    unittest.main()
