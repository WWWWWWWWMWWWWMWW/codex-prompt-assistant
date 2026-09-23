#!/usr/bin/env python3
"""User-launched one-shot diagnosis; no install, restart, paste, or send."""
import json
from pathlib import Path
import subprocess
import sys
import uuid
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
RESULT = ROOT / '.build' / 'focused-id-diagnosis.json'
EXPECTED = '01a084c0-b489-7e63-9c5f-d22637f6adae'

def save_record(record, latest=RESULT):
    history = latest.parent / 'focused-id-diagnoses'
    history.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    run_id = stamp + '-' + uuid.uuid4().hex[:12]
    record = dict(record, runId=run_id)
    payload = json.dumps(record, ensure_ascii=False, indent=2) + '\n'
    archive = history / (run_id + '.json')
    with archive.open('x') as stream:
        stream.write(payload)
    temporary = latest.with_name('.' + run_id + '.tmp')
    try:
        temporary.write_text(payload)
        temporary.replace(latest)
    finally:
        temporary.unlink(missing_ok=True)
    return record, archive


def main():
    listing = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True)
    candidates = []
    for line in listing.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == '/Applications/ChatGPT.next-8109.app/Contents/MacOS/ChatGPT':
            candidates.append(int(fields[0]))
    record = {'checkedAt': datetime.now(timezone.utc).isoformat()}
    if len(candidates) != 1:
        record.update(success=False, reason='running_codex_not_unique', candidateCount=len(candidates))
    else:
        print('正在编译并检查当前 Codex 任务，请暂时不要打字或复制。', flush=True)
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('run.py')),
            '--pid', str(candidates[0]), '--copy-current-thread-id', '--activate',
            '--focus-composer', '--production-resolver', '--verify-local-source', '--verify-context-body'],
            capture_output=True, text=True)
        try:
            output = json.loads(result.stdout)
        except ValueError:
            output = {'success': False, 'reason': 'probe_build_or_output_failed'}
        if 'threadId' in output:
            output['currentTaskMatches'] = output.pop('threadId') == EXPECTED
        allowed = {'success', 'reason', 'error', 'latencyMs', 'localSourceVerified',
            'sourceReason', 'currentTaskMatches', 'frontmostMatches', 'focusRole', 'windowAvailable',
            'contextAvailability', 'contextMessageCount', 'contextUserCount', 'contextAssistantCount',
            'contextMarkerA', 'contextMarkerB', 'contextReadReady', 'contextProbeExitCode'}
        record.update({k: v for k, v in output.items() if k in allowed})
        record['exitCode'] = result.returncode
    record, archive = save_record(record)
    print(json.dumps(record, ensure_ascii=False, indent=2))
    print('本次记录已独立保存：' + archive.name)
    print('可以继续切换任务并再次运行；全部完成后告诉助手“测试完成”。')
    return 0 if record.get('success') and record.get('localSourceVerified') and record.get('contextReadReady') else 1

if __name__ == '__main__':
    raise SystemExit(main())
