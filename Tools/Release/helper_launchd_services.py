"""launchd boundary for update_transaction; no deployment CLI.

Construction and inspection are read-only, including for a dirty personal build.
Mutations require clean, signed, lifecycle/health-capable packages. Only the fixed
helper service is controlled; configuration and protected services are never edited.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import time

from helper_agent import configuration
from helper_health import helper_stopped, inspect_health
from helper_runtime import inspect_runtime
from preflight_update import HELPER, MODEL, process_identity, run_read_command, service_pid
from prepare_update import inspect, require, verify_signature


class HelperLaunchdServices:
    def __init__(self, installed, service_plist, expected_installed_sha256,
                 codex_pid, model_pid, runner=run_read_command, signal_probe=os.kill,
                 signature_check=verify_signature, health_reader=inspect_health,
                 wait=time.sleep, attempts=20):
        self.installed = Path(installed)
        self.service_plist = Path(service_plist)
        self.codex_pid, self.model_pid = codex_pid, model_pid
        self.runner, self.signal_probe = runner, signal_probe
        self.signature_check, self.health_reader = signature_check, health_reader
        require(type(attempts) is int and 1 <= attempts <= 50, 'invalid_poll_bound')
        self.wait, self.attempts = wait, attempts
        self._configuration = configuration(self.installed.parent.parent)
        self._config_hash = self._read_configuration()
        initial = self._runtime(self.installed, expected_installed_sha256, codex_pid, model_pid)
        self._protected = (initial['processes']['codex'], initial['processes']['model'])
        self._remember(initial)
        self._start_pending = False
        self._guard()

    def _domain(self):
        return f'gui/{os.getuid()}'

    def _read_configuration(self):
        path = self.service_plist
        require(path.is_absolute() and path.resolve() == path
                and path.is_relative_to(self.installed.parent.parent) and path.is_file(),
                'service_config_path_unsupported')
        with path.open('rb') as stream:
            data = stream.read(65537)
        require(len(data) <= 65536, 'service_config_too_large')
        require(plistlib.loads(data) == self._configuration, 'service_configuration_mismatch')
        return hashlib.sha256(data).hexdigest()

    def _runtime(self, installed, digest, codex_pid, model_pid):
        result = inspect_runtime(installed, digest, codex_pid, model_pid,
                                 self.runner, self.signature_check)
        require(result['servicePath'] == str(self.service_plist)
                and result['serviceSHA256'] == self._config_hash, 'loaded_configuration_changed')
        return result

    def _remember(self, result):
        self._helper = result['processes']['helper']
        self._bundle = result['bundle']

    def protected_identity(self):
        require(service_pid(MODEL, self.runner) == self.model_pid, 'model_pid_mismatch')
        return (process_identity(self.codex_pid, self.runner),
                process_identity(self.model_pid, self.runner))

    def helper_stopped(self):
        if self._start_pending:
            return None  # No PID is yet bound to this attempted launch.
        return helper_stopped(self._helper['pid'], self.runner, self.signal_probe)

    def preserves_resident_model(self):
        require(not self._start_pending, 'unresolved_helper_launch')
        require(self._read_configuration() == self._config_hash, 'service_configuration_changed')
        if self.helper_stopped() is True:
            # Must work even between renaming original.app and installing candidate.
            return True
        current = self._runtime(self.installed, self._bundle['executableSHA256'],
                                self.codex_pid, self.model_pid)
        require(current['processes']['helper'] == self._helper
                and current['bundle'] == self._bundle, 'running_helper_changed')
        return True

    def _guard(self):
        require(self.protected_identity() == self._protected, 'protected_process_changed')
        require(self.preserves_resident_model() is True, 'model_protection_unknown')

    def _clean_capable_bundle(self):
        bundle = inspect(self.installed, self.signature_check)
        info = plistlib.loads((self.installed / 'Contents/Info.plist').read_bytes())
        for key in ('CPAUpdateLifecycleVersion', 'CPAHealthProtocolVersion'):
            require(type(info.get(key)) is int and info[key] == 1, 'bundle_capability_missing')
        require(inspect(self.installed, self.signature_check) == bundle, 'bundle_changed')
        return bundle

    def stop_helper(self):
        self._guard()
        require(self.helper_stopped() is False, 'helper_not_known_running')
        require(self._clean_capable_bundle() == self._bundle, 'running_bundle_changed')
        self._guard()
        self.runner(['/bin/launchctl', 'bootout', f'{self._domain()}/{HELPER}'])
        for attempt in range(self.attempts):
            require(self.protected_identity() == self._protected, 'protected_process_changed')
            require(self._read_configuration() == self._config_hash, 'service_configuration_changed')
            stopped = self.helper_stopped()
            require(stopped is not None, 'helper_stop_unknown')
            if stopped:
                return
            if attempt + 1 < self.attempts:
                self.wait(0.1)
        raise TimeoutError('helper_stop_timeout')

    def start_helper(self):
        self._guard()
        require(self.helper_stopped() is True, 'helper_stop_unconfirmed')
        expected = self._clean_capable_bundle()
        self._guard()
        command_error = None
        self._start_pending = True
        try:
            self.runner(['/bin/launchctl', 'bootstrap', self._domain(), str(self.service_plist)])
        except (OSError, subprocess.SubprocessError) as error:
            # A failed command may have launched a process. Observe it before
            # allowing the transaction to choose recovery, never blindly retry.
            command_error = error
        for attempt in range(self.attempts):
            require(self.protected_identity() == self._protected, 'protected_process_changed')
            require(self._read_configuration() == self._config_hash, 'service_configuration_changed')
            try:
                current = self._runtime(self.installed, expected['executableSHA256'],
                                        self.codex_pid, self.model_pid)
                require(current['bundle'] == expected, 'started_bundle_changed')
            except (OSError, ValueError, subprocess.SubprocessError):
                if attempt + 1 < self.attempts:
                    self.wait(0.1)
                continue
            self._remember(current)  # Track even an unhealthy but identified process.
            self._start_pending = False
            if command_error is not None:
                raise command_error
            return
        raise TimeoutError('helper_start_identity_timeout')

    def healthy_helper(self, expected):
        self._guard()
        result = self.health_reader(self.installed, expected['executableSHA256'],
                                    self.codex_pid, self.model_pid, runtime_reader=self._runtime)
        self._guard()
        return (result.get('healthVerified') is True and result.get('bundle') == expected
                and result.get('processes', {}).get('helper') == self._helper)
