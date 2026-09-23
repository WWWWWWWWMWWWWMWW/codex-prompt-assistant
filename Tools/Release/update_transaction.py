"""Finite helper-only update transaction. No CLI or built-in service commands.

The injected synchronous services adapter must establish stopped/running identity,
not infer it from a successful launch command or from the installed file alone.
Real launchd integration is a separate release gate.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import tempfile

from prepare_update import copy_bundle, inspect, require, verify_preparation, verify_signature


def write_journal(directory, record):
    pending = directory / 'journal.pending'
    with pending.open('w') as stream:
        json.dump(record, stream, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    pending.replace(directory / 'journal.json')


def move(source, destination):
    require(not destination.exists() and not destination.is_symlink(), 'move destination already exists')
    source.rename(destination)


def require_model_preservation(bundle, expected, signature_check):
    """Bind the lifecycle declaration to the already verified preparation."""
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    version = info.get('CPAUpdateLifecycleVersion') if isinstance(info, dict) else None
    require(type(version) is int and version == 1, 'bundle lacks resident-model preservation')
    require(inspect(bundle, signature_check) == expected, 'bundle changed during capability check')


def update(prepared, installed, services, signature_check=verify_signature,
           copier=copy_bundle, mover=move):
    """Never mutate configuration, permissions, or model/Codex service state.

    services: protected_identity() returns a nonempty stable tuple only if Codex
    and the resident model are present; helper_stopped() returns True only after
    confirmed absence; stop_helper/start_helper target the fixed helper only;
    healthy_helper(expected) checks the running build and health, not just disk.
    preserves_resident_model() must return True only if the running helper (when
    present) and the configuration used for both future starts carry the model
    protection option. After stop it must still verify the future launch config.
    Missing/unknown protection rejects before stop; later drift halts recovery.
    Unknown state and interruption require operator inspection; no automatic resume.
    """
    installed = Path(installed).absolute()
    record = {'schema': 1, 'outcome': 'running', 'phase': 'preflight'}
    directory = None
    touched_service = False
    confirmed_stop = False
    lock = None

    def checkpoint(phase):
        record['phase'] = phase
        write_journal(directory, record)

    def guard():
        require(services.protected_identity() == protected, 'protected process changed')
        require(services.preserves_resident_model() is True, 'helper model protection unverified')

    def finish(outcome, error=None):
        record['outcome'] = outcome
        if error is not None:
            record['errorType'] = type(error).__name__  # no raw process output or user content
        if directory is not None:
            record['directory'] = str(directory)
            try:
                write_journal(directory, record)
            except OSError:
                record['outcome'] = 'needs_attention'
                record['journalWriteFailed'] = True
        return dict(record)

    try:
        require(installed.resolve() == installed, 'installation path must not contain symlinks')
        key = hashlib.sha256(str(installed).encode()).hexdigest()[:16]
        prefix = '.cpa-update-' + key + '-'
        lock = (installed.parent / (prefix + 'lock')).open('a')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for previous in installed.parent.glob(prefix + '*'):
            if previous.is_dir():
                journal = json.loads((previous / 'journal.json').read_text())
                require(journal.get('outcome') in ('updated', 'rolled_back', 'rejected'),
                        'previous transaction requires inspection')
        bundles = verify_preparation(Path(prepared), signature_check)['bundles']
        for role, name in (('candidate', 'candidate.app'), ('rollback', 'rollback.app')):
            require_model_preservation(Path(prepared) / name, bundles[role], signature_check)
        require(inspect(installed, signature_check) == bundles['rollback'], 'installation changed since preparation')
        protected = services.protected_identity()
        require(isinstance(protected, tuple) and len(protected) == 2 and all(protected),
                'protected process identities required')
        guard()
        require(services.helper_stopped() is False, 'initial helper state must be known running')
        require(services.healthy_helper(bundles['rollback']) is True, 'running old helper identity must match backup')
        record['bundles'] = bundles
        record['protected'] = protected
        directory = Path(tempfile.mkdtemp(prefix=prefix, dir=installed.parent))
        checkpoint('stage_candidate')
        copier(Path(prepared) / 'candidate.app', directory / 'candidate.app')
        require(inspect(directory / 'candidate.app', signature_check) == bundles['candidate'], 'staged candidate mismatch')
        require(inspect(installed, signature_check) == bundles['rollback'], 'installation changed before stop')
        guard()
        checkpoint('stop_old_helper')
        touched_service = True
        services.stop_helper()
        guard()
        require(services.helper_stopped() is True, 'helper stop is unconfirmed')
        confirmed_stop = True
        checkpoint('preserve_original')
        require(inspect(installed, signature_check) == bundles['rollback'], 'installation changed after stop')
        mover(installed, directory / 'original.app')
        guard()
        checkpoint('install_candidate')
        mover(directory / 'candidate.app', installed)
        require(inspect(installed, signature_check) == bundles['candidate'], 'installed candidate mismatch')
        guard()
        checkpoint('start_candidate')
        services.start_helper()
        guard()
        require(services.healthy_helper(bundles['candidate']) is True, 'candidate health/identity unconfirmed')
        guard()
        return finish('updated')
    except (Exception, KeyboardInterrupt) as error:
        if not touched_service:
            return finish('rejected', error)
        if not confirmed_stop or isinstance(error, KeyboardInterrupt):
            return finish('needs_attention', error)
        # At most one rollback attempt, and only while protected identities match.
        try:
            guard()
            checkpoint('stop_before_rollback')
            if services.helper_stopped() is not True:
                services.stop_helper()
            guard()
            require(services.helper_stopped() is True, 'cannot restore while helper state is uncertain')
            original = directory / 'original.app'
            if original.exists():
                require(inspect(original, signature_check) == bundles['rollback'], 'saved original is invalid')
                if installed.exists():
                    require(inspect(installed, signature_check) == bundles['candidate'], 'unexpected installation during rollback')
                    checkpoint('preserve_failed_candidate')
                    mover(installed, directory / 'failed.app')
                guard()
                checkpoint('restore_original')
                mover(original, installed)
            require(inspect(installed, signature_check) == bundles['rollback'], 'restored package mismatch')
            guard()
            checkpoint('start_rollback')
            services.start_helper()
            guard()
            require(services.healthy_helper(bundles['rollback']) is True, 'rollback health/identity unconfirmed')
            guard()
            return finish('rolled_back', error)
        except (Exception, KeyboardInterrupt) as recovery_error:
            record['initialErrorType'] = type(error).__name__
            return finish('needs_attention', recovery_error)
    finally:
        if lock is not None:
            lock.close()
