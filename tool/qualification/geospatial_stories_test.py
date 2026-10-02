import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import geospatial_stories as stories


def response():
    return {
        'schema': 2, 'suite': 'geospatial-native-stories', 'passed': True,
        'platform': 'android', 'cleanup': 'passed',
        'diagnostics': dict.fromkeys(
            ['sessions', 'renderers', 'retiring', 'readbackBytes', 'surfaces'], 0),
        'scenes': [{
            'sourcePath': 'storybook/src/clouds/3DTilesRenderer.stories.tsx',
            'export': 'London', 'preset': 'london', 'rendering': 'passed',
            'comparison': 'not run', 'backend': 'Vulkan', 'presentation': 'sharedTexture',
            'logicalViewport': [1000, 600], 'physicalViewport': [640, 384],
            'inputs': {'cloudCoverage': .35},
            'assets': [{key: asset[key] for key in ('uri', 'sha256', 'bytes')}
                       for asset in stories.asset_manifest()['assets']],
            'checks': {'centerPickDistance': 20, 'cameraDisplacement': 0,
                       'visibleTiles': 29, 'tilePayloadBytes': 1000000,
                       'effects': 30, 'sourceCredits': 1, 'readbackBytes': 0,
                       'cloudHistoryFrames': 16},
        }],
    }


class QualificationTest(unittest.TestCase):
    def test_atmosphere_scenes_require_only_the_four_atmosphere_tables(self):
        value = response()
        scene = value['scenes'][0]
        scene.update(
            sourcePath='storybook/src/atmosphere/3DTilesRenderer.stories.tsx',
            export='Manhattan', preset='manhattan',
            inputs={'cloudCoverage': None},
            assets=[{key: asset[key] for key in ('uri', 'sha256', 'bytes')}
                    for asset in stories.asset_manifest()['assets']
                    if asset['group'] == 'atmosphere'],
        )
        self.assertEqual(len(scene['assets']), 4)
        stories.validate_response(value, stories.preset_identity('manhattan'))

    def test_asset_bytes_must_match_every_required_pinned_input(self):
        expected = stories.preset_identity('london')
        for mutate in [
            lambda value: value['scenes'][0].pop('assets'),
            lambda value: value['scenes'][0]['assets'].pop(),
            lambda value: value['scenes'][0]['assets'][0].update(sha256='0' * 64),
            lambda value: value['scenes'][0]['assets'][0].update(bytes=1),
            lambda value: value['scenes'][0]['assets'].append(
                value['scenes'][0]['assets'][0]),
        ]:
            value = response()
            mutate(value)
            with self.assertRaises(ValueError):
                stories.validate_response(value, expected)

    def test_native_presentation_matches_the_platform(self):
        expected = stories.preset_identity('london')
        for platform, backend, presentation, resource in [
            ('android', 'Vulkan', 'sharedTexture', 'surfaces'),
            ('iOS', 'Metal', 'nativeView', 'heldDrawables'),
            ('macOS', 'Metal', 'nativeView', 'heldDrawables'),
        ]:
            value = response()
            value['platform'] = platform
            value['diagnostics'][resource] = 0
            value['scenes'][0].update(backend=backend, presentation=presentation)
            stories.validate_response(value, expected)
            value['scenes'][0]['presentation'] = 'readback'
            with self.assertRaises(ValueError):
                stories.validate_response(value, expected)

    def test_catalog_keeps_all_source_identities_without_inferred_passes(self):
        _, cases = stories.catalog()
        self.assertEqual(len(cases), 74)
        self.assertEqual(sum(c['implementation'] == 'native scene registered'
                             for c in cases.values()), 5)
        self.assertTrue(all(c['rendering'] == 'not run' and c['comparison'] == 'not run'
                            for c in cases.values()))

    def test_completed_native_scene_and_cleanup_are_required(self):
        original = response()
        expected = stories.preset_identity('london')
        stories.validate_response(original, expected)
        for mutate in [
            lambda value: value['scenes'].clear(),
            lambda value: value.update(cleanup='not run'),
            lambda value: value['diagnostics'].pop('surfaces'),
            lambda value: value['diagnostics'].update(renderers=1),
        ]:
            changed = copy.deepcopy(original)
            mutate(changed)
            with self.assertRaises(ValueError):
                stories.validate_response(changed, expected)

    def test_component_results_cannot_claim_story_image_parity(self):
        for mutation in [
            {'comparison': 'passed'}, {'backend': 'WebGL'},
            {'presentation': 'readback'}, {'export': 'Unknown'},
            {'physicalViewport': [0, 384]},
        ]:
            value = response()
            value['scenes'][0].update(mutation)
            with self.assertRaises(ValueError):
                stories.validate_response(value, stories.preset_identity('london'))

    def test_failed_picking_and_incomplete_history_are_rejected(self):
        for mutation in [
            {'centerPickDistance': None}, {'centerPickDistance': 5000},
            {'cameraDisplacement': float('nan')}, {'cloudHistoryFrames': 15},
            {'readbackBytes': 4}, {'sourceCredits': 0},
        ]:
            value = response()
            value['scenes'][0]['checks'].update(mutation)
            with self.assertRaises(ValueError):
                stories.validate_response(value, stories.preset_identity('london'))

    def test_report_does_not_promote_failed_or_changed_runs(self):
        revision, _ = stories.catalog()
        evidence = {
            'sourceRevision': revision, 'story': stories.preset_identity('london'),
            'response': response(), 'exitCode': 0, 'sourceUnchanged': True,
            'before': {'digest': 'first', 'head': 'revision'},
            'after': {'digest': 'first'}, 'qualified': True,
        }
        with tempfile.TemporaryDirectory() as directory:
            path, output = Path(directory) / 'evidence.json', Path(directory) / 'report.json'
            for variant, expected in [
                ({}, 1), ({'exitCode': 1}, 0), ({'sourceUnchanged': False}, 0),
                ({'after': {'digest': 'changed'}}, 0),
            ]:
                path.write_text(json.dumps(evidence | variant))
                stories.report(SimpleNamespace(evidence=[path], output=output))
                result = json.loads(output.read_text())
                self.assertEqual(result['renderedScenes'], expected)
                self.assertEqual(result['comparedScenes'], 0)
                self.assertEqual(result['caseCount'], 74)


if __name__ == '__main__':
    unittest.main()
