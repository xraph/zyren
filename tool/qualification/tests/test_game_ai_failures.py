import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'verify_game_ai_failures.py'
spec = importlib.util.spec_from_file_location('failures', MODULE)
failures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(failures)


class FailureMatrixTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.receipt = {'schemaVersion': 1, 'cases': {name: {
            'status': 'passed', 'actualStatus': 'rejected',
            'before': {'identity': 'same'}, 'after': {'identity': 'same'},
            'cleanupCounters': {'before': {'owners': 0}, 'after': {'owners': 0}},
            'recovery': {'action': 'retry', 'status': 'passed'},
            'execution': {'kind': 'native', 'command': 'fixture command', 'exitCode': 0},
        } for name in failures.REQUIRED_CASES}}
        self.matrix = {'schemaVersion': 1, 'cases': {name: {
            'condition': 'injected fixture failure', 'expectedStatus': 'rejected',
            'preservedIdentities': ['identity'], 'cleanupCounters': ['owners'],
            'recoveryAction': 'retry', 'status': 'passed',
        } for name in failures.REQUIRED_CASES}}
        self.pin()

    def pin(self):
        path = self.root / 'receipt.json'
        path.write_text(json.dumps(self.receipt))
        for value in self.matrix['cases'].values():
            value['evidence'] = {'path': 'receipt.json', 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}

    def test_complete_actual_cases_pass(self):
        self.assertEqual(failures.validate(self.matrix, self.root), [])

    def test_missing_case_and_skip_never_pass(self):
        del self.matrix['cases']['model.hash']
        self.receipt['cases']['model.schema']['status'] = 'skipped'
        self.pin()
        self.assertTrue(failures.validate(self.matrix, self.root))

    def test_explicit_blocker_is_schema_valid_and_release_incomplete(self):
        self.matrix['cases']['renderer.loss'] = {
            **self.matrix['cases']['renderer.loss'], 'status': 'blocked', 'reason': 'No backend available.'}
        self.assertEqual(failures.validate(self.matrix, self.root, release=False), [])
        self.assertTrue(failures.validate(self.matrix, self.root))

    def test_mutated_identity_leaked_owner_or_failed_recovery_rejects(self):
        for key in ('after', 'cleanupCounters', 'recovery'):
            with self.subTest(key=key):
                original = copy.deepcopy(self.receipt)
                row = self.receipt['cases']['save.failed']
                if key == 'after':
                    row[key]['identity'] = 'changed'
                elif key == 'cleanupCounters':
                    row[key]['after']['owners'] = 1
                else:
                    row[key]['status'] = 'failed'
                self.pin()
                self.assertTrue(failures.validate(self.matrix, self.root))
                self.receipt = original

    def test_unlisted_identity_mutation_is_rejected(self):
        self.receipt['cases']['save.failed']['before']['document'] = {'unchanged': True}
        self.receipt['cases']['save.failed']['after']['document'] = {'unchanged': False}
        self.pin()
        self.assertTrue(failures.validate(self.matrix, self.root))

    def test_native_lifetime_case_cannot_use_pure_test(self):
        self.receipt['cases']['renderer.loss']['execution']['kind'] = 'pure'
        self.pin()
        self.assertTrue(failures.validate(self.matrix, self.root))

    def test_changed_receipt_and_escape_reject(self):
        (self.root / 'receipt.json').write_text('{}')
        self.assertTrue(failures.validate(self.matrix, self.root))
        self.matrix['cases']['model.hash']['evidence']['path'] = '../outside.json'
        self.assertTrue(failures.validate(self.matrix, self.root))


if __name__ == '__main__':
    unittest.main()
