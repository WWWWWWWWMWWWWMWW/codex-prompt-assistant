#!/usr/bin/env python3
"""Replay fixed synthetic candidates through a same-provider, judge-only audit."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
from run import ROOT, validate, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=['local','remote'], required=True)
    parser.add_argument('--version',choices=['audit-v1','audit-v2'],default='audit-v1')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, default=ROOT/'Tools/CompletionQualityBenchmark/fixtures/audit84.json')
    args = parser.parse_args()
    fixtures = json.loads(args.fixtures.read_text())
    validate(fixtures)
    cases = [f for f in fixtures if f['provider']==args.provider]
    if args.output.exists() or args.output.with_suffix('.manifest.json').exists() or not cases:
        parser.error('require new output paths and nonempty provider cases')
    for f in cases:
        if not isinstance(f.get('candidate'), str) or not f['candidate'] or f['audit_expected'] not in ('allow','reject','ambiguous'):
            parser.error('invalid audit fixture')
    subprocess.run(['make','build/CompletionQualityBenchmark'], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    binary = ROOT/'build/CompletionQualityBenchmark'
    manifest = dict(code_sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        worktree_dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT)),
        fixture_sha256=digest(args.fixtures),binary_sha256=digest(binary),audit_version=args.version,audit_prompt_sha256=digest(ROOT/f'Tools/CompletionQualityBenchmark/{args.version}.txt'),
        provider=args.provider,seed=90803,rounds=1,shared_deadline_ms=13000,
        scope='replay of previously generated or hand-authored synthetic candidates; not live generation plus audit',
        sources={p.name:digest(p) for p in Path(__file__).parent.iterdir() if p.is_file()})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix('.manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    random.Random(90803).shuffle(cases)
    with tempfile.TemporaryDirectory(prefix='cpa-audit-') as tmp, args.output.open('x') as output:
        path = Path(tmp)/'case.json'
        for sequence,f in enumerate(cases,1):
            path.write_text(json.dumps([f],ensure_ascii=False))
            env = dict(os.environ,CPA_BENCHMARK_AUDIT='1',CPA_BENCHMARK_AUDIT_VERSION=args.version,CPA_BENCHMARK_VARIANT='baseline',CPA_BENCHMARK_FIXTURES=str(path))
            env.pop('CPA_BENCHMARK_CHAT',None)
            env.pop('CPA_BENCHMARK_REPLAY',None)
            env.pop('CPA_BENCHMARK_REMOTE',None)
            if args.provider=='remote': env['CPA_BENCHMARK_REMOTE']='1'
            try:
                result=subprocess.run([str(binary)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
                if result.returncode: raise ValueError('runner failure')
                row=json.loads(result.stdout)
                if not isinstance(row,dict) or row['id']!=f['id']: raise ValueError('wrong candidate identity')
                if not {'stage','decision','audit_ms'}.issubset(row): raise ValueError('incomplete attempt')
            except (ValueError, KeyError, subprocess.TimeoutExpired):
                row=dict(id=f['id'],family_id=f['family_id'],provider=args.provider,decision=None,reason=None,raw=None,stage='system_failure',outcome='runner_failure',audit_ms=None)
            row.update(sequence=sequence,audit_version=args.version,audit_expected=f['audit_expected'],source_variant=f['source_variant'],
                candidate_sha256=hashlib.sha256(f['candidate'].encode()).hexdigest(),generation_ms=f['generation_ms'])
            row['replay_sum_ms']=f['generation_ms']+row['audit_ms'] if row['audit_ms'] is not None else None
            output.write(json.dumps(row,ensure_ascii=False)+'\n');output.flush()
            print(f"{sequence}/{len(cases)} {f['id']} {row['stage']} {row['decision']}",flush=True)


if __name__=='__main__': main()
