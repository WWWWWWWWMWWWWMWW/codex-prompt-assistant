import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools/Release'))
import helper_health as health


class HealthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['CPA_TEST_ROOT'])
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / 'helper.app'
        (self.bundle / 'Contents').mkdir(parents=True)
        (self.bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CPAHealthProtocolVersion':1}))
        self.runtime = {'processes':{'helper':{'pid':11}}, 'bundle':{'build':{'fixture':'build'}},
                        'blockers':['live_health_not_verified','real_rollback_not_verified']}
        self.receipt = {'schema':1, 'pid':11, 'uid':os.getuid(), 'build':{'fixture':'build'},
                        'nonce':str(uuid.uuid4()), 'instance':str(uuid.uuid4()),
                        'mainThreadResponsive':True, 'eventTapEnabled':True,
                        'accessibilityGranted':True, 'modelPreserved':True, 'private':'do not return'}
        self.calls = []

    def probe(self, arguments):
        self.calls.append(arguments)
        return json.dumps(self.receipt)

    def inspect(self, **options):
        return health.inspect_health(self.bundle, 'fixture', 33, 22,
            runtime_reader=options.get('runtime_reader', lambda *a:copy.deepcopy(self.runtime)),
            probe=options.get('probe', self.probe))

    def test_success_is_bound_and_does_not_grant_update_permission(self):
        result = self.inspect()
        self.assertTrue(result['healthVerified']);self.assertFalse(result['automaticUpdateReady'])
        self.assertNotIn('private', json.dumps(result))
        self.assertEqual(self.calls[0][1:], ['--health-probe','11'])
        self.assertEqual(result['blockers'], ['real_rollback_not_verified'])

    def test_false_input_state_is_reported_unhealthy(self):
        for key in ['mainThreadResponsive','eventTapEnabled','accessibilityGranted','modelPreserved']:
            self.receipt[key] = False
            self.assertFalse(self.inspect()['healthVerified'])
            self.receipt[key] = True

    def test_identity_schema_and_state_mismatch_rejected(self):
        for key,value in [('pid',12),('uid',-1),('schema',True),('build',{}),('nonce','invalid'),('instance',None),('eventTapEnabled',1)]:
            original = self.receipt[key];self.receipt[key] = value
            with self.subTest(key=key),self.assertRaises(ValueError):self.inspect()
            self.receipt[key] = original

    def test_runtime_changes_rejected(self):
        count = 0
        def read(*args):
            nonlocal count
            count += 1
            value = copy.deepcopy(self.runtime)
            if count == 2:value['processes']['helper']['pid'] = 12
            return value
        with self.assertRaises(ValueError):self.inspect(runtime_reader=read)

    def test_legacy_bundle_never_executed(self):
        (self.bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({}))
        with self.assertRaises(ValueError):self.inspect()
        self.assertEqual(self.calls,[])

    def test_timeout_remains_unknown(self):
        def timeout(args):raise subprocess.TimeoutExpired(args,5)
        with self.assertRaises(subprocess.TimeoutExpired):self.inspect(probe=timeout)


class StoppedTests(unittest.TestCase):
    def absent(self,args):
        raise subprocess.CalledProcessError(113,args,stderr=f'Bad request.\nCould not find service "{health.HELPER}" in domain for user gui: {os.getuid()}\n')

    def gone(self,pid,signal):
        self.assertEqual((pid,signal),(11,0));raise ProcessLookupError()

    def test_service_absent_and_exact_pid_gone_required(self):
        self.assertIs(health.helper_stopped(11,self.absent,self.gone),True)
        self.assertIs(health.helper_stopped(11,self.absent,lambda *args:None),False)
        self.assertIs(health.helper_stopped(11,lambda args:'running',self.gone),False)

    def test_service_error_and_permission_errors_are_unknown(self):
        for code,text in [(5,'denied'),(113,'unknown'),(113,'Could not find service "other"')]:
            def failed(args):raise subprocess.CalledProcessError(code,args,stderr=text)
            self.assertIsNone(health.helper_stopped(11,failed,self.gone))
        def denied(*args):raise PermissionError()
        self.assertIsNone(health.helper_stopped(11,self.absent,denied))

    def test_invalid_pid_rejected(self):
        for pid in [0,-1,True]:
            with self.assertRaises(ValueError):health.helper_stopped(pid,self.absent,self.gone)


if __name__ == '__main__':unittest.main()
