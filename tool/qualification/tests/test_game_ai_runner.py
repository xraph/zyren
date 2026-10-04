import copy
import importlib.util
import json
import contextlib
import io
from types import SimpleNamespace
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'run_game_ai.py'
spec = importlib.util.spec_from_file_location('game_ai_runner', MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def distribution(value=1000, count=36000):
    return {'count': count, 'p50': value, 'p95': value, 'p99': value,
            'raw': [value] * count}


class GameAiRunnerTest(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads(runner.PROFILES.read_text())['profiles']['reference-guard']
        self.device = {'id': 'fixture-device', 'emulator': False, 'targetPlatform': 'android-arm64'}
        self.receipt = {
            'schemaVersion': 1, 'profile': self.profile, 'status': 'passed',
            'durationSeconds': 600, 'diagnostics': [], 'frames': 36000,
            'identity': {'device': 'fixture-device', 'physicalDevice': True,
                         'buildHash': 'source-pin', 'buildMode': 'profile',
                         'os': 'Android 17', 'renderer': 'vulkan',
                         'provider': 'native-onnxruntime-1.23.2-cpu',
                         'gameHash': 'a' * 64, 'modelHashes': ['b' * 64],
                         'schemaHashes': ['c' * 64]},
            'cleanupVerified': True, 'loadVerified': True, 'actorLoadVerified': True,
            'nativePresentation': True, 'visualInputsVerified': False,
            'dueDecisions': 30000, 'completedDecisions': 30000, 'missedDecisions': 0,
            'invalidActions': 0, 'staleActionsApplied': 0, 'readbackBytes': 0,
            'modelBytes': 1024, 'peakRssBytes': 100000,
            'peakTensorBytes': 1024, 'peakRecurrentBytes': 1024,
            'lifecycle': ['camera-movement', 'spawn', 'despawn', 'pause', 'resume',
                          'renderer-recreated'],
            'fullFrameMicros': distribution(), 'presentationMicros': distribution(),
            'flutterFrameMicros': distribution(),
            'gamePerceptionCpuMicros': distribution(count=30000),
            'inferenceRoundTripMicros': distribution(count=30000),
            'clockWakeLatenessMicros': distribution(value=100, count=30000),
            'clockPendingSteps': distribution(value=0, count=30000),
            'clockAdvancedSteps': 30000, 'clockDroppedSeconds': 0.0,
            'nativeRenderBuildMicros': distribution(count=36000),
            'nativeRenderSubmitMicros': distribution(count=36000),
            'nativeRenderGpuMicros': None,
            'nativeOutputSizes': [{'width': 960, 'height': 2061, 'frames': 36000}],
            'nativeOwnersBefore': {'sessions': 0, 'surfaces': 0, 'renderers': 0, 'retiring': 0},
            'nativeOwnersAfter': {'sessions': 0, 'surfaces': 0, 'renderers': 0, 'retiring': 0},
            'mlOwnersBefore': {'sessions': 0, 'results': 0, 'runs': 0},
            'mlOwnersAfter': {'sessions': 0, 'results': 0, 'runs': 0},
            'physicsOwnersBefore': {'worlds': 0, 'bodies': 0},
            'physicsOwnersAfter': {'worlds': 0, 'bodies': 0},
        }

    def validate(self, receipt=None, **kwargs):
        return runner.validate_receipt(receipt if receipt is not None else self.receipt,
                                       self.profile, self.device, 'source-pin', **kwargs)

    def test_valid_full_receipt_and_exact_device(self):
        self.assertEqual(self.validate(), [])
        self.assertEqual(runner.physical_device([self.device], self.device['id']), self.device)
        for change in ({'emulator': True}, {'targetPlatform': 'web-javascript'}, {'id': 'other'}):
            with self.assertRaises(ValueError):
                runner.physical_device([{**self.device, **change}], self.device['id'])

    def test_passed_status_does_not_replace_raw_gates(self):
        mutations = [
            ('cleanupVerified', False), ('dueDecisions', 30001), ('durationSeconds', 10),
            ('frames', 100), ('loadVerified', False), ('actorLoadVerified', False),
            ('nativePresentation', False), ('invalidActions', 1), ('staleActionsApplied', 1),
            ('modelBytes', 0), ('peakRssBytes', 0), ('readbackBytes', 4),
            ('lifecycle', ['pause'] * 6), ('diagnostics', ['budget exceeded']),
            ('fullFrameMicros', distribution(17000)),
            ('gamePerceptionCpuMicros', distribution(2001, 30000)),
            ('inferenceRoundTripMicros', distribution(count=0)),
            ('inferenceRoundTripMicros', distribution(count=1)),
            ('clockAdvancedSteps', 29999), ('clockDroppedSeconds', .02),
            ('clockWakeLatenessMicros', None),
            ('clockPendingSteps', distribution(value=65, count=30000)),
            ('nativeOwnersAfter', {**self.receipt['nativeOwnersAfter'], 'retiring': 1}),
            ('mlOwnersAfter', {**self.receipt['mlOwnersAfter'], 'runs': 1}),
            ('physicsOwnersAfter', {'worlds': 0, 'bodies': 1}),
            ('nativeOwnersBefore', {}), ('mlOwnersBefore', None),
        ]
        for key, value in mutations:
            with self.subTest(key=key):
                self.assertTrue(self.validate({**self.receipt, key: value}))
        candidate = copy.deepcopy(self.receipt)
        candidate.update(completedDecisions=29000, missedDecisions=1000)
        self.assertTrue(self.validate(candidate))
        candidate.update(dueDecisions=10, completedDecisions=10, missedDecisions=0)
        self.assertTrue(self.validate(candidate))

    def test_raw_samples_recompute_counts_and_percentiles(self):
        for value in (None, True, -1, float('nan'), 1.5):
            candidate = copy.deepcopy(self.receipt)
            candidate['fullFrameMicros']['raw'][0] = value
            self.assertTrue(self.validate(candidate))
        for key, value in (('count', 1), ('p95', 0), ('p99', 0), ('raw', [])):
            candidate = copy.deepcopy(self.receipt)
            candidate['fullFrameMicros'][key] = value
            self.assertTrue(self.validate(candidate))
        candidate = copy.deepcopy(self.receipt)
        candidate['fullFrameMicros']['raw'] = [20000] * 36000
        self.assertTrue(self.validate(candidate))

    def test_render_workload_cannot_omit_output_dimensions_or_native_timings(self):
        for sizes in (None, [], [{'width': 0, 'height': 2061, 'frames': 36000}],
                      [{'width': 960, 'height': 2061, 'frames': 1}],
                      [{'width': 960, 'height': 2061, 'frames': 18000}] * 2):
            self.assertTrue(self.validate({**self.receipt, 'nativeOutputSizes': sizes}))
        for key, value in (('nativeRenderBuildMicros', distribution(count=1)),
                           ('nativeRenderSubmitMicros', None),
                           ('nativeRenderGpuMicros', distribution(count=36001))):
            self.assertTrue(self.validate({**self.receipt, key: value}))
        self.assertEqual(self.validate({**self.receipt, 'nativeRenderGpuMicros': distribution(count=123)}), [])
        mixed = copy.deepcopy(self.receipt)
        mixed['nativeOutputSizes'] = [{'width': 32, 'height': 32, 'frames': 35999},
                                      {'width': 960, 'height': 2061, 'frames': 1}]
        self.assertIn('sustained output size changed during measurement', self.validate(mixed))
        mixed.update(status='failed', durationSeconds=10, diagnostics=['duration'])
        self.assertEqual(self.validate(mixed, smoke=True), [])

    def test_native_identity_and_visual_proof_are_required(self):
        for key, value in (('device', 'other'), ('buildHash', 'other'), ('buildMode', 'debug'),
                           ('renderer', 'opengl'), ('provider', 'fake'), ('modelHashes', []),
                           ('gameHash', ''), ('schemaHashes', [])):
            candidate = copy.deepcopy(self.receipt)
            candidate['identity'][key] = value
            self.assertTrue(self.validate(candidate))
        visual = copy.deepcopy(self.receipt)
        profile = json.loads(runner.PROFILES.read_text())['profiles']['mobile-visual']
        visual['profile'] = profile
        self.assertTrue(runner.validate_receipt(visual, profile, self.device, 'source-pin'))

    def test_short_receipt_cannot_establish_qualification(self):
        receipt = copy.deepcopy(self.receipt)
        receipt.update(status='failed', durationSeconds=10, diagnostics=['duration'], frames=100,
                       dueDecisions=10, completedDecisions=10, missedDecisions=0)
        for name in ('fullFrameMicros', 'presentationMicros', 'flutterFrameMicros',
                     'gamePerceptionCpuMicros', 'inferenceRoundTripMicros',
                     'nativeRenderBuildMicros', 'nativeRenderSubmitMicros'):
            receipt[name] = distribution(count=100)
        receipt['nativeOutputSizes'][0]['frames'] = 100
        receipt['clockWakeLatenessMicros'] = distribution(value=100, count=100)
        receipt['clockPendingSteps'] = distribution(value=0, count=100)
        receipt['clockAdvancedSteps'] = 100
        self.assertEqual(self.validate(receipt, smoke=True), [])
        self.assertTrue(self.validate(receipt))
        self.assertTrue(self.validate(smoke=True))
        self.assertTrue(self.validate({**receipt, 'completedDecisions': 0,
                                       'missedDecisions': 10}, smoke=True))
        self.assertTrue(self.validate({**receipt, 'mlOwnersAfter': {}}, smoke=True))

    def test_changed_inputs_reject_sustained_and_label_smoke(self):
        self.assertTrue(self.validate(inputs_stable=False))
        run = {'profile': self.profile['id'], 'verified': True, 'inputsStable': False, 'repetition': 1,
               'comparisonKey': 'a' * 64}
        summary = runner.summarize([run], [self.profile], True)
        self.assertEqual(summary['status'], 'smokeUnstable')
        self.assertEqual(summary['profiles'][self.profile['id']]['status'], 'smokeUnstable')

    def test_all_three_repetitions_are_required(self):
        run = {'profile': self.profile['id'], 'verified': True, 'inputsStable': True,
               'comparisonKey': 'a' * 64}
        runs = [{**run, 'repetition': n + 1} for n in range(3)]
        self.assertEqual(runner.summarize(runs[:2], [self.profile], False)['status'], 'failed')
        self.assertEqual(runner.summarize(runs, [self.profile], False)['status'], 'passed')
        self.assertEqual(runner.summarize(runs[:1], [self.profile], True)['status'], 'smokeOnly')
        for mutated in ([runs[0]] * 3, runs[:2] + [{**runs[2], 'verified': False}],
                        runs[:2] + [{**runs[2], 'inputsStable': False}],
                        runs[:2] + [{**runs[2], 'comparisonKey': None}],
                        runs[:2] + [{**runs[2], 'comparisonKey': 'b' * 64}]):
            self.assertEqual(runner.summarize(mutated, [self.profile], False)['status'], 'failed')

    def test_main_records_both_source_pins_and_unstable_smoke(self):
        receipt = copy.deepcopy(self.receipt)
        receipt.update(status='failed', durationSeconds=10, diagnostics=['duration'])
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            def invoke(command, **kwargs):
                if command[2] == 'devices':
                    return SimpleNamespace(stdout=json.dumps([self.device]))
                Path(kwargs['env']['GAME_BENCHMARK_RECEIPT']).write_text(json.dumps(receipt))
                return SimpleNamespace(returncode=0)
            with patch('sys.argv', ['run_game_ai', '--device', self.device['id'], '--smoke',
                                    '--profile', self.profile['id'], '--output', str(output)]), \
                    patch.object(runner.subprocess, 'run', side_effect=invoke), \
                    patch.object(runner, 'source_hash', side_effect=['source-pin', 'changed']), \
                    patch.object(runner, 'build_artifacts', return_value=[{'sha256': 'complete-app'}]), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(runner.main(), 0)
            summary = json.loads((output / 'summary.json').read_text())
            run = summary['profiles'][self.profile['id']]['runs'][0]
            self.assertEqual(summary['status'], 'smokeUnstable')
            self.assertEqual(run['sourceHashBefore'], 'source-pin')
            self.assertEqual(run['sourceHashAfter'], 'changed')
            self.assertFalse(run['inputsStable'])
            self.assertEqual(run['status'], 'smokeUnstable')
            self.assertRegex(run['comparisonKey'], r'^[0-9a-f]{64}$')
            self.assertIn('--dart-define=GAME_BENCHMARK_BUILD_HASH=source-pin', run['command'])

    def test_macos_bundle_pins_frameworks_and_internal_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            bundle = app / 'build/macos/Build/Products/Profile/Game.app'
            (bundle / 'Contents/MacOS').mkdir(parents=True)
            (bundle / 'Contents/Frameworks/App.framework/Versions/A').mkdir(parents=True)
            (bundle / 'Contents/MacOS/Game').write_bytes(b'runner')
            code = bundle / 'Contents/Frameworks/App.framework/Versions/A/App'
            code.write_bytes(b'dart-native-code')
            (code.parent.parent / 'Current').symlink_to('A', target_is_directory=True)
            with patch.object(runner, 'APP', app):
                first = runner.build_artifacts('darwin-arm64', 'profile')
                code.write_bytes(b'changed-dart-native-code')
                second = runner.build_artifacts('darwin-arm64', 'profile')
                self.assertNotEqual(first[0]['sha256'], second[0]['sha256'])
                self.assertEqual(first[0]['totalBytes'], len(b'runnerdart-native-code'))
                self.assertTrue(any(f.get('target') == 'A' for f in first[0]['files']))
                (bundle / 'Contents/external').symlink_to(app / 'outside')
                with self.assertRaises(ValueError):
                    runner.build_artifacts('darwin-arm64', 'profile')

    def test_bundle_inventory_has_bounds_and_android_apk_is_self_contained(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            apk = app / 'build/app/outputs/flutter-apk/app-profile.apk'
            apk.parent.mkdir(parents=True)
            apk.write_bytes(b'full-apk')
            with patch.object(runner, 'APP', app):
                artifact = runner.build_artifacts('android-arm64', 'profile')[0]
                self.assertEqual(artifact['bytes'], 8)
                with self.assertRaises(ValueError):
                    runner.bundle_inventory(apk.parent, max_files=0)
                with self.assertRaises(ValueError):
                    runner.bundle_inventory(apk.parent, max_bytes=1)


if __name__ == '__main__':
    unittest.main()
