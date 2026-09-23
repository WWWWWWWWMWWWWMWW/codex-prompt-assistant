#!/usr/bin/env python3
"""Paired synthetic-only experiment; explicit --provider remote uses saved credentials.

No tuning or semantic judging. Gold metadata is never serialized to the model.
Public fixtures are development data, not independently sealed blind tests.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(fixtures):
    if not isinstance(fixtures, list) or not fixtures:
        raise ValueError('nonempty fixture array required')
    ids, families = set(), {}
    for f in fixtures:
        if f['id'] in ids:
            raise ValueError('duplicate fixture id')
        ids.add(f['id'])
        if families.setdefault(f['family_id'], f['split']) != f['split']:
            raise ValueError('family crosses splits')
        for field in ('before_cursor', 'after_cursor'):
            if not isinstance(f[field], str):
                raise ValueError('cursor fields must be strings')
        if f['context']['availability'] not in ('ready', 'ready_empty', 'missing', 'ambiguous', 'loading', 'error'):
            raise ValueError('unknown context availability')
        for m in f['context']['messages']:
            if m['role'] not in ('user', 'assistant') or not isinstance(m['content'], str):
                raise ValueError('invalid selected message')
        if len(f['before_cursor'].encode('utf-16-le')) // 2 > 2000:
            raise ValueError('fixture exceeds current draft budget')
        messages = f['context']['messages']
        if sum(len(m['content'].encode('utf-16-le')) // 2 for m in messages) > 3000:
            raise ValueError('fixture exceeds selected context budget')
        for role, count, length in [('user', 6, 400), ('assistant', 2, 300)]:
            selected = [m for m in messages if m['role'] == role]
            if len(selected) > count or any(len(m['content'].encode('utf-16-le')) // 2 > length for m in selected):
                raise ValueError('fixture exceeds per-role context budget')
        for evidence in f.get('evidence', []):
            source = f['before_cursor'] if evidence['field'] == 'before_cursor' else messages[0]['content']
            if evidence['quote'] not in source:
                raise ValueError('evidence excerpt differs from supplied input')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--provider', choices=['local', 'remote'], default='local')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=1)
    parser.add_argument('--candidate', choices=['g1', 'context-v1'], default='g1')
    parser.add_argument('--seed', type=int, default=90802)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 3:
        parser.error('rounds must be between 1 and 3')
    fixtures = json.loads(args.fixtures.read_text())
    validate(fixtures)
    if args.output.exists() or args.output.with_suffix('.manifest.json').exists():
        parser.error('refusing to overwrite an experiment')
    subprocess.run(['make', 'build/CompletionQualityBenchmark'], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    binary = ROOT / 'build/CompletionQualityBenchmark'
    sources = list((ROOT / 'Sources/RemoteCompletionCore').glob('*.[mh]'))
    sources += list(Path(__file__).parent.glob('*'))
    manifest = dict(schema=1, code_sha=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        worktree_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
        fixture_sha256=digest(args.fixtures), binary_sha256=digest(binary), seed=args.seed,
        provider=args.provider, rounds=args.rounds, deadline_ms=13000,
        scope='isolated client + text display eligibility; no UI, debounce, AX or credential preparation timing',
        context_metadata_sent=args.candidate == 'context-v1', candidate=args.candidate, cache='fresh client per attempt',
        sources={str(p.relative_to(ROOT)): digest(p) for p in sources if p.is_file()})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix('.manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
    rng = random.Random(args.seed)
    sequence = 0
    with args.output.open('x') as output, tempfile.TemporaryDirectory(prefix='cpa-c2-') as tmp:
        case_path = Path(tmp) / 'fixture.json'
        for repeat in range(1, args.rounds+1):
            order = fixtures[:]
            rng.shuffle(order)
            for f in order:
                variants = ['baseline', args.candidate]
                rng.shuffle(variants)
                case_path.write_text(json.dumps([f], ensure_ascii=False))
                for variant in variants:
                    sequence += 1
                    env = dict(os.environ)
                    for name in ('CPA_BENCHMARK_REMOTE', 'CPA_BENCHMARK_CHAT', 'CPA_BENCHMARK_AUDIT', 'CPA_BENCHMARK_REPLAY'):
                        env.pop(name, None)
                    env.update(CPA_BENCHMARK_FIXTURES=str(case_path), CPA_BENCHMARK_VARIANT=variant)
                    if args.provider == 'remote':
                        env['CPA_BENCHMARK_REMOTE'] = '1'
                    try:
                        run = subprocess.run([str(binary)], cwd=ROOT, env=env, capture_output=True, text=True, timeout=20)
                        if run.returncode:
                            raise RuntimeError(f'runner_exit_{run.returncode}')
                        row = json.loads(run.stdout)
                        if row['id'] != f['id'] or row['variant'] != variant:
                            raise RuntimeError('runner_identity_mismatch')
                    except (subprocess.TimeoutExpired, RuntimeError, ValueError) as error:
                        row = dict(id=f['id'], family_id=f['family_id'], provider=args.provider, variant=variant,
                            stage='system_failure', outcome=type(error).__name__, raw=None,
                            protocol_candidate=None, client_candidate=None, display_candidate=None,
                            first_segment_ms=None, decision_ms=None, ui_display_ms=None, semantic_label='unreviewed')
                    row.update(round=repeat, sequence=sequence, split=f['split'], expected=f['expected'])
                    output.write(json.dumps(row, ensure_ascii=False)+'\n')
                    output.flush()
                    print(f"{sequence}: {args.provider} {variant} {f['id']} {row['stage']}", flush=True)


if __name__ == '__main__':
    main()
