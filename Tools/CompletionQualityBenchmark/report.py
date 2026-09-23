#!/usr/bin/env python3
"""Describe an experiment without treating nonempty output as semantic success."""
import argparse
from collections import Counter, defaultdict
import json
import hashlib
import math
from pathlib import Path


def percentile(values, p):
    values = sorted(values)
    return values[max(0, math.ceil(p * len(values))-1)] if values else None


def summarize(rows, reviews):
    groups = defaultdict(list)
    for row in rows:
        groups[(row['provider'], row['variant'], row['round'])].append(row)
    reports = []
    for (provider, variant, repeat), group in sorted(groups.items()):
        continue_rows = [r for r in group if r['expected'] == 'continue']
        stop_rows = [r for r in group if r['expected'] == 'stop' and r['stage'] != 'capability_rejection']
        shown = [r for r in group if r['display_candidate']]
        valid, invalid, unresolved, times = [], [], [], []
        labels = Counter()
        families = defaultdict(set)
        raw_labels = Counter()
        raw_count = sum(bool(r.get('raw')) for r in group)
        for row in group:
            key = '|'.join([provider, variant, str(repeat), row['id']])
            review = reviews.get(key, {})
            for field in ('raw', 'display_candidate'):
                if review:
                    value = row.get(field)
                    fingerprint = hashlib.sha256(value.encode()).hexdigest() if value is not None else None
                    if review.get(field+'_sha256') != fingerprint:
                        raise ValueError('review does not match exact candidate: '+key)
            raw_labels.update(review.get('raw_labels', []))
        for row in shown:
            key = '|'.join([provider, variant, str(repeat), row['id']])
            review = reviews.get(key, {})
            decision = review.get('decision', 'unreviewed')
            if decision == 'valid':
                valid.append(row)
                if row['decision_ms'] is not None: times.append(row['decision_ms'])
            elif decision == 'invalid': invalid.append(row)
            else: unresolved.append(row)
            for label in review.get('labels', []):
                labels[label] += 1; families[label].add(row['family_id'])
        coverage = sum(r['expected'] == 'continue' for r in valid)
        stop = sum(r['stage'] in ('model_abstention','pre_generation_rejection','quality_rejection') for r in stop_rows)
        reports.append(dict(provider=provider, variant=variant, round=repeat, attempts=len(group),
            continue_valid=[coverage,len(continue_rows)], semantic_stop_no_display=[stop,len(stop_rows)],
            display_qualified=[len(valid),len(shown)] if shown else None,
            invalid_display=len(invalid), unresolved_display=len(unresolved),
            ambiguous=sum(r['expected']=='ambiguous' for r in group),
            raw_candidates=raw_count, raw_labels=dict(raw_labels),
            stages=dict(Counter(r['stage'] for r in group)), display_labels=dict(labels),
            decision_by_stage={stage:dict(n=sum(r['stage']==stage for r in group),
                p50=percentile([r['decision_ms'] for r in group if r['stage']==stage and r['decision_ms'] is not None],.5),
                p95=percentile([r['decision_ms'] for r in group if r['stage']==stage and r['decision_ms'] is not None],.95))
                for stage in sorted({r['stage'] for r in group})},
            affected_families={k:len(v) for k,v in families.items()},
            decision_ms=dict(p50=percentile([r['decision_ms'] for r in group if r['decision_ms'] is not None],.5),
                p95=percentile([r['decision_ms'] for r in group if r['decision_ms'] is not None],.95),
                observed=sum(r['decision_ms'] is not None for r in group)),
            valid_candidate_ms=dict(p50=percentile(times,.5),p95=percentile(times,.95),n=len(times)),
            ui_display_latency='unmeasured'))
    return reports


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('records', type=Path, nargs='+')
    parser.add_argument('--reviews', type=Path, required=True)
    args = parser.parse_args()
    rows = [json.loads(line) for p in args.records for line in p.read_text().splitlines()]
    print(json.dumps(summarize(rows, json.loads(args.reviews.read_text())), ensure_ascii=False, indent=2))
