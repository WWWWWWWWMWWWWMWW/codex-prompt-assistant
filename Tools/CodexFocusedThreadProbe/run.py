#!/usr/bin/env python3
"""Build a one-shot, explicit Copy deeplink probe. Never starts or restarts an app."""
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


def verify_source(identifier):
    codex = Path.home() / '.codex'
    with sqlite3.connect((codex / 'state_5.sqlite').as_uri() + '?mode=ro', uri=True) as db:
        rows = db.execute('SELECT rollout_path FROM threads WHERE id = ? LIMIT 2', (identifier,)).fetchall()
    if len(rows) != 1:
        return {'localSourceVerified': False, 'sourceReason': 'not_unique'}
    path = Path(rows[0][0]).resolve()
    if not path.is_relative_to(codex.resolve()) or path.suffix != '.jsonl':
        return {'localSourceVerified': False, 'sourceReason': 'outside_local_log_scope'}
    with path.open('rb') as stream:
        # Read only the bounded session header; do not read or output message bodies.
        line = stream.readline(64 * 1024)
    header = json.loads(line)
    matches = header.get('type') == 'session_meta' and header.get('payload', {}).get('id') == identifier
    return {'localSourceVerified': matches, 'sourceReason': 'id_matches_header' if matches else 'header_mismatch'}


def main():
    args = sys.argv[1:]
    verify_body = '--verify-context-body' in args
    args = [a for a in args if a != '--verify-context-body']
    verify = '--verify-local-source' in args
    args = [a for a in args if a != '--verify-local-source']
    with tempfile.TemporaryDirectory(prefix='cpa-focused-id-') as directory:
        binary = Path(directory) / 'probe'
        subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-framework', 'AppKit', '-framework', 'ApplicationServices',
                        str(Path(__file__).with_name('main.m')),
                        str(Path(__file__).resolve().parents[2] / 'Sources/CodexPromptAssistantPOC/CodexThreadIDResolver.m'),
                        '-o', str(binary)], check=True)
        # The native probe has a bounded copy wait and restores the clipboard before exit.
        result = subprocess.run([str(binary), *args], capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout.strip() or json.dumps({'error': 'native_probe_failed'}))
            return result.returncode
        output = json.loads(result.stdout)
        if verify and output.get('threadId'):
            try:
                output.update(verify_source(output['threadId']))
            except (OSError, sqlite3.Error, ValueError):
                output.update(localSourceVerified=False, sourceReason='source_read_failed')
        if verify_body and output.get('localSourceVerified'):
            context_binary = Path(directory) / 'context-probe'
            root = Path(__file__).resolve().parents[2]
            subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                '-framework', 'Foundation', '-lsqlite3', str(Path(__file__).with_name('context.m')),
                str(root / 'Sources/CodexPromptAssistantPOC/ConversationContextProvider.m'),
                '-o', str(context_binary)], check=True)
            codex = Path.home() / '.codex'
            body = subprocess.run([str(context_binary), output['threadId'], str(codex / 'sessions'),
                str(codex / 'state_5.sqlite')], capture_output=True, text=True, timeout=5)
            output.update(json.loads(body.stdout))
            output['contextProbeExitCode'] = body.returncode
        print(json.dumps(output, ensure_ascii=False, sort_keys=True))
        if verify_body and output.get('localSourceVerified') and not output.get('contextReadReady'):
            return 6
        return 0 if not verify or output.get('localSourceVerified') else 5


if __name__ == '__main__':
    raise SystemExit(main())
