import copy
import hashlib
import importlib.util
import json
import re
import struct
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'verify_game_ai_release.py'
spec = importlib.util.spec_from_file_location('release', MODULE)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'receipt.json').write_text('{"exit_code":0}\n')
        self.pin = {
            'path': 'receipt.json',
            'sha256': hashlib.sha256((self.root / 'receipt.json').read_bytes()).hexdigest(),
            'description': 'Fixture receipt for evaluator tests, not game qualification.',
        }
        passed = {'status': 'passed', 'evidence': [self.pin]}
        record = {name: copy.deepcopy(passed) for name in release.DIMENSIONS}
        record['targets'] = {
            name: {'status': 'passed', 'evidence': [self.write_receipt(name + '.json', {
                'schemaVersion': 1, 'kind': 'nativeExecution', 'target': name,
                'backend': name.split('-')[1], 'status': 'passed', 'skipped': False,
                'exitCode': 0, 'buildMode': 'profile', 'physicalDevice': 'fixture-device',
            })]} for name in release.TARGETS
        }
        self.report = self.evaluation_fixture()
        models, parity = {}, {}
        for family in ('guard', 'vehicle'):
            (self.root / (family + '.onnx')).write_bytes(b'qualification evaluator fixture, not a model')
            models[family] = self.write_pin(family + '.onnx')
            parity[family] = self.write_parity(family, models[family]['sha256'])
        self.report['family_model_hashes'] = {f: pin['sha256'] for f, pin in models.items()}
        self.quality = {
            'schemaVersion': 1, 'kind': 'trainedArtifact', 'status': 'passed',
            'accepted': True, 'models': models, 'nativeParity': parity,
            'evaluation': self.write_receipt('evaluation.json', self.report),
        }
        record['trainedArtifact'] = {'status': 'passed', 'evidence': [
            self.write_receipt('quality.json', self.quality)]}
        self.document = {
            'schemaVersion': 1,
            'requiredTargets': sorted(release.TARGETS),
            'requirements': {name: copy.deepcopy(record) for name in release.REQUIREMENTS},
            'tasks': {name: copy.deepcopy(record) for name in release.TASKS},
        }

    def write_parity(self, family, model_hash):
        width = 278 if family == 'guard' else 259
        values = [0.0] * width
        values[0 if family == 'guard' else 3] = 64.0
        native = values.copy()
        native[0 if family == 'guard' else 3] += 0.0000152587890625
        tensor = struct.pack('<' + 'f' * (2 * width), *(values + native)) * 1000
        tensor_name = family + '-tensors.f32'
        (self.root / tensor_name).write_bytes(tensor)
        controls = []
        for step in range(1000):
            action = {'continuous': [], 'discrete': [0] * 6} if family == 'guard' else {'continuous': [0.0] * 3, 'discrete': []}
            row = {'step': step, 'reference': action, 'native': copy.deepcopy(action)}
            if family == 'guard': row['legality'] = [[True] * n for n in (5,5,5,3,2,2)]
            controls.append(row)
        control_pin = self.write_receipt(family + '-controls.json', controls)
        maximum = 0.0000152587890625
        return self.write_receipt(family + '-parity.json', {
            'schema_version': 1, 'status': 'passed', 'provider': 'native-onnxruntime-1.23.2-cpu',
            'steps': 1000, 'typed_controller_steps': 1000, 'completed_runs': 1000,
            'live_sessions': 0, 'live_results': 0, 'model_sha256': model_hash,
            'max_absolute_error': maximum, 'max_normalized_error': maximum / (1e-5 + 1e-4 * 64),
            'atol': 1e-5, 'rtol': 1e-4, 'input_sequence_hash': '1' * 64,
            'native_worker_sha256': '2' * 64,
            'native_asset_sha256': {'lib/libzyren_ml.dylib': '3' * 64, 'lib/libonnxruntime.dylib': '4' * 64},
            'tensor_evidence': {'path': tensor_name, 'sha256': hashlib.sha256(tensor).hexdigest(),
                'bytes': len(tensor), 'dtype': 'float32-le', 'shape': [1000,2,width],
                'tensor_widths': {'logits' if family == 'guard' else 'action': 22 if family == 'guard' else 3, 'next_hidden': 128, 'next_cell': 128}},
            'control_evidence': {'path': control_pin['path'], 'sha256': control_pin['sha256'],
                'bytes': (self.root / control_pin['path']).stat().st_size, 'steps': 1000},
        })

    def evaluation_fixture(self):
        plan = json.loads((release.ROOT / 'tool/zyren_train/configs/evaluation.yaml').read_text())
        rows, coverage = [], {}
        for case in plan['cases']:
            settings = case['scenario']['settings']
            labels = ['friction', 'unfamiliar-layouts']
            if settings.get('target_speed', 0) > 0:
                labels.append('moving-target')
            if settings.get('curriculum_stage') in ('occlusion', 'task-combinations'):
                labels.append('occlusion-memory')
            if settings.get('curriculum_stage') in ('moving-hazards', 'task-combinations'):
                labels.append('moving-hazards')
            if case['stress']['miss_every']:
                labels.extend(['missed-decisions', 'fallback-recovery'])
            if case['stress']['delay_every']:
                labels.extend(['delayed-observations', 'fallback-recovery'])
            coverage[case['id']] = sorted(set(labels))
            for seed in case['seeds']:
                rows.append(release.EpisodeMetric(len(rows), seed, case['scenario']['id'],
                    case['family'], 'completed', True, False, 1.0, 1.0, 240,
                    fallback_steps=1 if case['stress']['miss_every'] or case['stress']['delay_every'] else 0))
        return {
            'schema_version': 1, 'plan': plan, 'plan_hash': release.EVALUATION_PLAN,
            'provider': 'python-onnxruntime-1.23.2-cpu', 'status': 'passed', 'reasons': [],
            'requested': len(rows), 'episodes': [row.to_dict() for row in rows],
            'metrics': {f: release.aggregate([row for row in rows if row.family == f],
                sum(row.family == f for row in rows)) for f in ('guard', 'vehicle')},
            'layout_seed_counts': {f: len({row.seed for row in rows if row.family == f})
                for f in ('guard', 'vehicle')},
            'hidden_state_leaks': 0, 'reward_exploits': 0, 'coverage_evidence': coverage,
            'stress_coverage': sorted({label for labels in coverage.values() for label in labels}),
            'worker_failures': 0, 'worker_exit_codes': [0],
            'worker_sha256': plan['worker_sha256'], 'worker_native_sha256': plan['worker_native_sha256'],
        }

    def write_pin(self, name):
        return {'path': name, 'sha256': hashlib.sha256((self.root / name).read_bytes()).hexdigest(),
                'description': 'Evaluator fixture only.'}

    def write_receipt(self, name, data):
        (self.root / name).write_text(json.dumps(data))
        return self.write_pin(name)

    def set_native_receipt(self, **changes):
        name = 'macos-metal'
        data = json.loads((self.root / (name + '.json')).read_text())
        data.update(changes)
        self.document['requirements']['R03']['targets'][name]['evidence'] = [
            self.write_receipt('bad-native.json', data)]

    def test_skipped_or_build_only_native_receipt_cannot_pass(self):
        for changes in ({'status': 'skipped'}, {'skipped': True}, {'exitCode': 1},
                        {'kind': 'build'}, {'status': 'failed'}):
            with self.subTest(changes=changes):
                self.set_native_receipt(**changes)
                self.assertTrue(release.validate(self.document, self.root))

    def test_native_target_backend_and_device_are_required(self):
        for changes in ({'target': 'ios-metal'}, {'backend': 'webgl'},
                        {'physicalDevice': ''}, {'buildMode': 'compile-only'}, {'buildMode': {}}):
            with self.subTest(changes=changes):
                self.set_native_receipt(**changes)
                self.assertTrue(release.validate(self.document, self.root))

    def test_hash_only_file_cannot_establish_native_execution(self):
        self.document['requirements']['R03']['targets']['macos-metal']['evidence'] = [self.pin]
        self.assertTrue(release.validate(self.document, self.root))

    def set_quality(self, value):
        self.document['requirements']['R20']['trainedArtifact']['evidence'] = [
            self.write_receipt('bad-quality.json', value)]

    def test_training_quality_requires_acceptance_and_heldout_execution(self):
        for changes in ({'accepted': False}, {'status': 'skipped'}, {'kind': 'export'}):
            with self.subTest(changes=changes):
                quality = copy.deepcopy(self.quality)
                quality.update(changes)
                self.set_quality(quality)
                self.assertTrue(release.validate(self.document, self.root))
        for changes in ({'status': 'failed'}, {'plan_hash': '0' * 64},
                        {'provider': 'torch-2.8.0-cpu'}, {'worker_exit_codes': []}):
            with self.subTest(changes=changes):
                report = copy.deepcopy(self.report)
                report.update(changes)
                quality = copy.deepcopy(self.quality)
                quality['evaluation'] = self.write_receipt('bad-evaluation.json', report)
                self.set_quality(quality)
                self.assertTrue(release.validate(self.document, self.root))

    def test_training_model_pin_cannot_change(self):
        (self.root / 'guard.onnx').write_bytes(b'changed')
        self.assertTrue(release.validate(self.document, self.root))

    def test_fixed_quality_gate_and_episode_coverage_cannot_be_relaxed(self):
        for mutation in ('threshold', 'outcome', 'denominator', 'collision', 'confidence', 'budget'):
            with self.subTest(mutation=mutation):
                report = copy.deepcopy(self.report)
                if mutation == 'threshold':
                    report['plan']['targets']['guard']['success_rate'] = 0
                elif mutation == 'outcome':
                    report['episodes'][0]['success'] = False
                elif mutation == 'budget':
                    report['episodes'].pop()
                else:
                    key = {'denominator': 'success_denominator', 'collision': 'collision_rate',
                           'confidence': 'success_lower95'}[mutation]
                    report['metrics']['vehicle'][key] = 0.5
                quality = copy.deepcopy(self.quality)
                quality['evaluation'] = self.write_receipt('bad-evaluation.json', report)
                self.set_quality(quality)
                self.assertTrue(release.validate(self.document, self.root))

    def test_public_runtime_plan_registry_and_provider_match_release_gate(self):
        source = (release.ROOT / 'packages/zyren_game_ai/lib/artifact.dart').read_text()
        body = re.search(r'structuredModelEvaluationPlanHashes\s*=\s*\{(.*?)\};', source, re.S)
        self.assertIsNotNone(body)
        self.assertEqual(set(re.findall(r"'[0-9a-f]{64}'", body.group(1))),
                         {"'" + value + "'" for value in release.EVALUATION_PLANS})
        report = copy.deepcopy(self.report)
        report['provider'] = 'python-onnxruntime-1.24.0-cpu'
        quality = copy.deepcopy(self.quality)
        quality['evaluation'] = self.write_receipt('provider-evaluation.json', report)
        self.set_quality(quality)
        self.assertTrue(release.validate(self.document, self.root))

    def test_audited_worker_revision_retains_original_quality_cases(self):
        report = copy.deepcopy(self.report)
        plan = report['plan']
        plan['id'] = 'game-lab-held-out-v1-artifact-3a46eec02cc1'
        plan['worker_sha256'] = '3a46eec02cc1e0cce4ef6fe3a09b4b09febb5f0746f11523c7407964be5c88fb'
        plan['revision'] = {'case_content_hash': 'b5a7eff352c517411b818b741e82c0a75bf330f254f78764fe2e43f307872f47', 'reason': 'original executable overwritten during sequence-probe rebuild', 'supersedes': '70293bb2509acec9f3626a87423f5a077d496e75cad3dc734f6fff853af763c4'}
        report['plan_hash'] = 'deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd'
        report['worker_sha256'] = plan['worker_sha256']
        quality = copy.deepcopy(self.quality)
        quality['evaluation'] = self.write_receipt('revision-evaluation.json', report)
        self.set_quality(quality)
        self.assertEqual(release.validate(self.document, self.root), [])
        plan['cases'][0]['seeds'][0] += 1
        quality['evaluation'] = self.write_receipt('changed-revision.json', report)
        self.set_quality(quality)
        self.assertTrue(release.validate(self.document, self.root))

    def test_dart_native_model_parity_is_required(self):
        for changes in ({'provider': 'python-onnxruntime-1.23.2-cpu'}, {'status': 'skipped'},
                        {'model_sha256': '0' * 64}, {'max_normalized_error': 1.01}):
            with self.subTest(changes=changes):
                quality = copy.deepcopy(self.quality)
                receipt = json.loads((self.root / 'guard-parity.json').read_text())
                receipt.update(changes)
                quality['nativeParity']['guard'] = self.write_receipt('bad-parity.json', receipt)
                self.set_quality(quality)
                self.assertTrue(release.validate(self.document, self.root))

    def test_relative_tolerance_accepts_bounded_tensor_error_above_absolute_threshold(self):
        self.assertEqual(release.validate(self.document, self.root), [])

    def test_native_parity_rejects_forged_tensor_and_typed_control_evidence(self):
        for change in ('tolerance', 'normalized', 'width', 'nan', 'diverged', 'controls', 'illegal', 'sequence', 'count', 'trailing', 'path', 'cleanup'):
            with self.subTest(change=change):
                self.write_parity('guard', self.quality['models']['guard']['sha256'])
                receipt = json.loads((self.root / 'guard-parity.json').read_text())
                if change == 'tolerance': receipt['rtol'] = 0.1
                elif change == 'normalized': receipt['max_normalized_error'] = 0.0
                elif change == 'width': receipt['tensor_evidence']['shape'][2] += 1
                elif change == 'count': receipt['steps'] = 16
                elif change == 'cleanup': receipt['live_sessions'] = 1
                elif change == 'path': receipt['tensor_evidence']['path'] = '../escape.f32'
                elif change in ('nan', 'diverged', 'trailing'):
                    name = receipt['tensor_evidence']['path']
                    data = bytearray((self.root / name).read_bytes())
                    if change == 'trailing': data.extend(b'0000')
                    else: struct.pack_into('<f', data, 278 * 4, float('nan') if change == 'nan' else 100.0)
                    (self.root / name).write_bytes(data)
                    receipt['tensor_evidence']['sha256'] = hashlib.sha256(data).hexdigest()
                    receipt['tensor_evidence']['bytes'] = len(data)
                else:
                    name = receipt['control_evidence']['path']
                    rows = json.loads((self.root / name).read_text())
                    if change == 'controls': rows[0]['native']['discrete'][0] = 1
                    elif change == 'illegal': rows[0]['legality'][0][0] = False
                    elif change == 'sequence': rows[1]['step'] = 0
                    pin = self.write_receipt(name, rows)
                    receipt['control_evidence'].update(sha256=pin['sha256'], bytes=(self.root / name).stat().st_size)
                quality = copy.deepcopy(self.quality)
                quality['nativeParity']['guard'] = self.write_receipt('bad-parity.json', receipt)
                self.set_quality(quality)
                self.assertTrue(release.validate(self.document, self.root))

    def test_durable_actual_t5_parity_receipts_recompute_with_fixed_tolerance(self):
        for family in ('guard', 'vehicle'):
            path = release.ROOT / ('tool/zyren_train/qualification/2026-10-03/' + family + '-parity.json')
            if not path.exists(): self.fail('Durable parity fixture missing')
            receipt = json.loads(path.read_text())
            self.assertTrue(release.validate_model_parity(path, receipt['model_sha256'], family, root=release.ROOT))

    def test_malformed_target_list_reports_diagnostics(self):
        self.document['requiredTargets'] = [{'target': 'macos-metal'}]
        self.assertTrue(release.validate(self.document, self.root))

    def test_complete_pinned_coverage(self):
        self.assertEqual(release.validate(self.document, self.root), [])

    def test_missing_task_and_requirement_cannot_pass(self):
        del self.document['tasks']['T6']
        del self.document['requirements']['R20']
        errors = release.validate(self.document, self.root)
        self.assertTrue(any('tasks.T6: missing' in error for error in errors))
        self.assertTrue(any('requirements.R20: missing' in error for error in errors))

    def test_blocker_is_schema_valid_but_release_fails(self):
        self.document['requirements']['R20']['targets']['ios-metal'] = {
            'status': 'blocked', 'reason': 'No physical iOS device available.',
        }
        self.assertEqual(release.validate(self.document, self.root, release=False), [])
        self.assertTrue(release.validate(self.document, self.root))

    def test_missing_or_changed_evidence_fails(self):
        (self.root / 'receipt.json').write_text('changed')
        self.assertTrue(any('changed evidence' in e for e in release.validate(self.document, self.root)))
        (self.root / 'receipt.json').unlink()
        self.assertTrue(any('missing evidence' in e for e in release.validate(self.document, self.root)))

    def test_required_native_or_trained_cannot_be_waived(self):
        self.document['requirements']['R20']['trainedArtifact'] = {
            'status': 'notApplicable', 'reason': 'A fixture ran.',
        }
        self.document['requirements']['R20']['targets'] = {}
        self.document['requiredTargets'] = []
        errors = release.validate(self.document, self.root, release=False)
        self.assertTrue(any('cannot be marked notApplicable' in e for e in errors))
        self.assertTrue(any('expected all five' in e for e in errors))
        self.assertTrue(any('preserve all five' in e for e in errors))

    def test_path_escape_and_false_pass_are_rejected(self):
        self.document['tasks']['Q1']['automated'] = {'status': 'passed', 'evidence': []}
        self.pin['path'] = '../outside.json'
        self.document['tasks']['Q2']['native'] = {'status': 'passed', 'evidence': [self.pin]}
        errors = release.validate(self.document, self.root)
        self.assertTrue(any('requires evidence' in e for e in errors))
        self.assertTrue(any('escapes the repository' in e for e in errors))


if __name__ == '__main__':
    unittest.main()
