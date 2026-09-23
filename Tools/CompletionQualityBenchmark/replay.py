#!/usr/bin/env python3
"""Replay fixed historical synthetic raw outputs, without invoking a model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT/'build/CompletionQualityBenchmark')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.with_suffix('.manifest.json').exists():
        parser.error('output must not exist')
    cases, sources = [], {}
    for experiment, stem, fixture_name in [('c2-g1','core-','core20'),('c2-g1','legacy-','legacy24'),('context-v1','','context24')]:
        fixture_path = ROOT/f'Tools/CompletionQualityBenchmark/fixtures/{fixture_name}.json'
        fixtures = {f['id']:f for f in json.loads(fixture_path.read_text())}
        sources[str(fixture_path.relative_to(ROOT))] = digest(fixture_path)
        for provider in ('local','remote'):
            path = ROOT/f'docs/evaluation/results/{experiment}/{stem}{provider}.jsonl'
            sources[str(path.relative_to(ROOT))] = digest(path)
            for line in path.read_text().splitlines():
                r = json.loads(line); f = fixtures[r['id']]
                cases.append(dict(id=f"{experiment}/{stem}{provider}/{r['variant']}/{r['round']}/{r['id']}",
                    before_cursor=f['before_cursor'], after_cursor=f.get('after_cursor',''), selection=f.get('selection',0),
                    raw=r['raw'], finish_reason=r.get('finish_reason'), recorded_stage=r['stage'],
                    recorded_display=r['display_candidate'], source_file=str(path.relative_to(ROOT)),
                    source_id=r['id'],source_variant=r['variant'],provider=provider,expected=r['expected']))
    with tempfile.TemporaryDirectory(prefix='cpa-filter-replay-') as tmp:
        case_path = Path(tmp)/'fixtures.json'
        case_path.write_text(json.dumps(cases,ensure_ascii=False))
        env = dict(os.environ,CPA_BENCHMARK_REPLAY=str(case_path))
        # The replay branch exits before provider/configuration access.
        result = subprocess.run([str(args.binary.resolve())],cwd=ROOT,env=env,
                                capture_output=True,text=True,timeout=30,check=True)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
    if [r['id'] for r in rows] != [f['id'] for f in cases]: raise ValueError('replay identity mismatch')
    for row, f in zip(rows,cases):
        row.update({k:f[k] for k in ('source_file','source_id','source_variant','provider','expected','recorded_stage','recorded_display')})
        row['raw_sha256']=hashlib.sha256(f['raw'].encode()).hexdigest() if f['raw'] is not None else None
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open('x') as out:
        for row in rows: out.write(json.dumps(row,ensure_ascii=False)+'\n')
    manifest=dict(scope='raw output filter replay only, no generation or UI',attempts=len(rows),sources=sources,
        binary_sha256=digest(args.binary),protocol_sha256=digest(ROOT/'Sources/RemoteCompletionCore/RemoteCompletionProtocol.m'),
        git_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        worktree_dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT)))
    args.output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'{len(rows)} fixed raw outputs replayed; no model requests')


if __name__=='__main__': main()
