import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'Tools/CompletionQualityBenchmark'/f'{name}.py')
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result
report, runner = module('report'), module('run')
audit_report = module('audit_report')

class AuditMetricsTests(unittest.TestCase):
    def fixture(self):
        return dict(id='one',candidate='exact',provider='local',audit_expected='reject',
                    source_variant='baseline',source_case='original',generation_ms=20)

    def row(self):
        import hashlib
        f=self.fixture()
        return dict(f,audit_version='audit-v1',stage='system_failure',decision=None,
                    outcome='invalid_response',audit_ms=30,replay_sum_ms=50,
                    candidate_sha256=hashlib.sha256(f['candidate'].encode()).hexdigest())

    def test_failure_and_ambiguity_are_not_successful_rejections(self):
        failure=self.row()
        ambiguous=dict(failure,id='two',audit_expected='ambiguous',stage='audit_decision',decision='reject')
        stats=audit_report.metrics([failure,ambiguous])
        self.assertEqual(stats['gold']['reject'],dict(total=1,allowed=0,rejected=0,failed=1))
        self.assertEqual(stats['gold']['ambiguous']['rejected'],1)

    def test_no_output_generation_remains_in_coverage_denominator(self):
        fixture=dict(self.fixture(),audit_expected='allow')
        row=dict(self.row(),audit_expected='allow',stage='audit_decision',decision='allow')
        source=[dict(id='original',expected='continue'),dict(id='failed-generation',expected='continue')]
        result=audit_report.summarize([row],[fixture],source)[0]
        self.assertEqual(result['sources']['baseline']['replay_continue_retained'],[1,2])

    def test_changed_candidate_duplicate_and_missing_rows_fail(self):
        fixture=self.fixture();row=self.row()
        for rows in ([dict(row,candidate_sha256='wrong')],[row,row]):
            with self.assertRaises(ValueError): audit_report.summarize(rows,[fixture],[])
        with self.assertRaises(ValueError):
            audit_report.summarize([row],[fixture,dict(fixture,id='missing')],[])

    def test_failed_allow_cannot_inflate_coverage(self):
        with self.assertRaises(ValueError):
            audit_report.summarize([dict(self.row(),decision='allow')],[self.fixture()],[])

class MetricsTests(unittest.TestCase):
    def row(self, **kw):
        return dict(dict(provider='local', variant='g1', round=1, expected='continue',
            stage='quality_rejection', display_candidate=None, id='one', family_id='f1',decision_ms=100), **kw)

    def test_all_rejected_is_zero_coverage_and_no_precision(self):
        row = report.summarize([self.row()], {})[0]
        self.assertEqual(row['continue_valid'],[0,1])
        self.assertIsNone(row['display_qualified'])
        self.assertIsNone(row['valid_candidate_ms']['p95'])

    def test_failures_do_not_count_as_correct_stop_or_fast_success(self):
        rows = [self.row(expected='stop',stage='system_failure',decision_ms=13000),
                self.row(expected='stop',stage='model_abstention',decision_ms=100)]
        row = report.summarize(rows,{})[0]
        self.assertEqual(row['semantic_stop_no_display'],[1,2])
        self.assertEqual(row['decision_ms']['p95'],13000)
        self.assertEqual(row['valid_candidate_ms']['n'],0)

    def test_nonempty_is_not_automatically_valid(self):
        row = report.summarize([self.row(stage='candidate',display_candidate='new fact')],{})[0]
        self.assertEqual(row['continue_valid'],[0,1])
        self.assertEqual(row['unresolved_display'],1)

    def test_separate_rounds_not_independent_families(self):
        self.assertEqual(len(report.summarize([self.row(),self.row(round=2)],{})),2)

    def test_review_cannot_be_reused_for_changed_candidate(self):
        with self.assertRaises(ValueError):
            report.summarize([self.row(stage='candidate',display_candidate='changed')],
                {'local|g1|1|one': {'decision':'valid','display_candidate_sha256':'old'}})

    def test_fixture_families_cannot_cross_splits(self):
        import json
        fixtures=json.loads((ROOT/'Tools/CompletionQualityBenchmark/fixtures/core20.json').read_text())
        runner.validate(fixtures)
        fixtures[1]['split']='holdout'
        with self.assertRaises(ValueError): runner.validate(fixtures)

if __name__ == '__main__': unittest.main()
