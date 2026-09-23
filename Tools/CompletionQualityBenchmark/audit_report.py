#!/usr/bin/env python3
"""Summarize exact-candidate replay; failures and ambiguous gold stay separate."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path


def timing(values):
    values = sorted(x for x in values if x is not None)
    return dict(n=len(values), p50=values[math.ceil(.5*len(values))-1] if values else None,
                p95=values[math.ceil(.95*len(values))-1] if values else None)


def metrics(rows):
    counts = {}
    for gold in ('allow', 'reject', 'ambiguous'):
        group = [r for r in rows if r['audit_expected'] == gold]
        counts[gold] = dict(total=len(group),
            allowed=sum(r['stage'] == 'audit_decision' and r['decision'] == 'allow' for r in group),
            rejected=sum(r['stage'] == 'audit_decision' and r['decision'] == 'reject' for r in group),
            failed=sum(r['stage'] != 'audit_decision' for r in group))
    return dict(attempts=len(rows), gold=counts,
        stages=dict(Counter(r['stage'] for r in rows)),
        failures=dict(Counter(r['outcome'] for r in rows if r['stage'] != 'audit_decision')),
        audit_ms=timing(r.get('audit_ms') for r in rows),
        audit_ms_by_stage={s:timing(r.get('audit_ms') for r in rows if r['stage']==s)
                           for s in sorted({r['stage'] for r in rows})},
        replay_sum_ms_estimate=timing(r.get('replay_sum_ms') for r in rows),
        mismatches=[r['id'] for r in rows if r['audit_expected'] != 'ambiguous'
                    and (r['stage'] != 'audit_decision' or r['decision'] != r['audit_expected'])])


def summarize(rows, fixtures, source_fixtures):
    indexed = {f['id']: f for f in fixtures}
    if len(indexed) != len(fixtures): raise ValueError('duplicate fixture ID')
    source_index = {f['id']: f for f in source_fixtures}
    denominator = sum(f['expected'] == 'continue' for f in source_fixtures)
    groups, seen = defaultdict(list), set()
    for row in rows:
        f = indexed[row['id']]
        key = (row['audit_version'], row['provider'], row['id'])
        if key in seen: raise ValueError('duplicate audit attempt')
        seen.add(key)
        if row['candidate_sha256'] != hashlib.sha256(f['candidate'].encode()).hexdigest():
            raise ValueError('candidate hash mismatch')
        for field in ('provider', 'audit_expected', 'source_variant', 'generation_ms'):
            if row[field] != f[field]: raise ValueError('fixture identity mismatch: '+field)
        if row['stage'] == 'audit_decision':
            if row['decision'] not in ('allow','reject'): raise ValueError('invalid decision')
        elif row['decision'] is not None:
            raise ValueError('failure cannot carry a decision')
        groups[key[:2]].append(row)
    results = []
    for (version, provider), group in sorted(groups.items()):
        if {r['id'] for r in group} != {f['id'] for f in fixtures if f['provider']==provider}:
            raise ValueError('incomplete provider run')
        sources = {}
        for source in sorted({r['source_variant'] for r in group}):
            subset = [r for r in group if r['source_variant']==source]
            sources[source] = metrics(subset)
            if source != 'hand-authored':
                good = [r for r in subset if r['audit_expected']=='allow'
                        and source_index[indexed[r['id']]['source_case']]['expected']=='continue']
                retained = sum(r['stage']=='audit_decision' and r['decision']=='allow' for r in good)
                # Keep original generation failures/no-output in the denominator.
                sources[source]['replay_continue_before'] = [len(good), denominator]
                sources[source]['replay_continue_retained'] = [retained, denominator]
        results.append(dict(version=version, provider=provider, **metrics(group), sources=sources))
    return results


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('records', type=Path, nargs='+')
    parser.add_argument('--fixtures',type=Path,default=root/'Tools/CompletionQualityBenchmark/fixtures/audit84.json')
    parser.add_argument('--source-fixtures',type=Path,default=root/'Tools/CompletionQualityBenchmark/fixtures/context24.json')
    args = parser.parse_args()
    rows = []
    for path in args.records:
        manifest = json.loads(path.with_suffix('.manifest.json').read_text())
        if manifest['fixture_sha256'] != hashlib.sha256(args.fixtures.read_bytes()).hexdigest():
            raise ValueError('manifest fixture mismatch')
        batch = [json.loads(line) for line in path.read_text().splitlines()]
        # Early v1 manifests predate version selection. Recover only from the
        # exact recorded template hash; never assume missing metadata means v1.
        version = manifest.get('audit_version')
        matching = [v for v in ('audit-v1','audit-v2') if hashlib.sha256(
            (root/f'Tools/CompletionQualityBenchmark/{v}.txt').read_bytes()).hexdigest()
            == manifest['audit_prompt_sha256']]
        if len(matching) != 1 or (version is not None and version != matching[0]):
            raise ValueError('manifest template mismatch')
        version = matching[0]
        if any(r['provider']!=manifest['provider'] or r['audit_version']!=version for r in batch):
            raise ValueError('manifest run identity mismatch')
        rows.extend(batch)
    print(json.dumps(summarize(rows,json.loads(args.fixtures.read_text()),
        json.loads(args.source_fixtures.read_text())),ensure_ascii=False,indent=2))
