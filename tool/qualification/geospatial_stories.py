#!/usr/bin/env python3
"""Run registered native city stories and report coverage of the pinned catalog."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
INVENTORY = ROOT / 'tool/reference/inventory.json'
PRESETS = {
    'manhattan': ('atmosphere', 'Manhattan'),
    'fuji': ('atmosphere', 'Fuji'),
    'tokyo': ('clouds', 'Tokyo'),
    'cloudFuji': ('clouds', 'Fuji'),
    'london': ('clouds', 'London'),
}
SOURCE_PATHS = [
    'packages/' + name for name in (
        'zyren', 'flutter_zyren', 'zyren_native', 'zyren_gltf',
        'zyren_3d_tiles', 'zyren_geospatial', 'zyren_effects',
    )
] + ['examples/planet', 'pubspec.yaml', 'pubspec.lock', '.fvmrc',
     'tool/qualification/geospatial_stories.py', 'tool/reference/inventory.json']


def identity(path, name):
    return f'{path}#{name}'


def preset_identity(preset):
    package, name = PRESETS[preset]
    return identity(f'storybook/src/{package}/3DTilesRenderer.stories.tsx', name)


def asset_manifest():
    return json.loads((ROOT / 'examples/planet/assets/qualification/source_assets.json').read_text())


def catalog():
    inventory = json.loads(INVENTORY.read_text())
    cases = {}
    for story in inventory['stories']:
        key = identity(story['path'], story['name'])
        if key in cases:
            raise ValueError(f'Duplicate source story: {key}')
        cases[key] = {
            'id': key, 'sourcePath': story['path'], 'export': story['name'],
            'title': story['title'], 'implementation': 'scene not registered',
            'rendering': 'not run', 'comparison': 'not run', 'runs': [],
        }
    for preset in PRESETS:
        cases[preset_identity(preset)]['implementation'] = 'native scene registered'
        cases[preset_identity(preset)]['preset'] = preset
    return inventory['revision'], cases


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode().strip()


def snapshot():
    names = git('ls-files', '-z', '--cached', '--others', '--exclude-standard',
                '--', *SOURCE_PATHS).split('\0')
    files = {}
    for name in sorted(set(names) - {''}):
        path = ROOT / name
        files[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    digest = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    return {'head': git('rev-parse', 'HEAD'), 'branch': git('branch', '--show-current'),
            'digest': digest, 'files': files}


def validate_response(response, expected):
    if not isinstance(response, dict) or response.get('schema') != 2:
        raise ValueError('Missing structured native response.')
    if response.get('suite') != 'geospatial-native-stories':
        raise ValueError('Response belongs to another qualification suite.')
    _, known = catalog()
    seen = set()
    for scene in response.get('scenes', []):
        key = identity(scene['sourcePath'], scene['export'])
        if key not in known or key in seen or key != expected:
            raise ValueError(f'Unexpected or duplicate story: {key}')
        seen.add(key)
        if scene.get('comparison') != 'not run':
            raise ValueError('A presentation test cannot certify an image comparison.')
        if scene.get('rendering') != 'passed':
            raise ValueError('Only completed per-scene checks belong in scenes.')
        groups = {'atmosphere', 'clouds'} if '/clouds/' in scene['sourcePath'] else {'atmosphere'}
        assets = scene.get('assets', [])
        expected_assets = [{key: asset[key] for key in ('uri', 'sha256', 'bytes')}
                           for asset in asset_manifest()['assets'] if asset['group'] in groups]
        if sorted(assets, key=lambda asset: asset['uri']) != sorted(expected_assets, key=lambda asset: asset['uri']):
            raise ValueError('Loaded assets do not match the pinned source hashes and sizes.')
        if scene.get('backend', '').lower() not in {'metal', 'vulkan', 'dx12', 'direct3d12'}:
            raise ValueError('The scene did not identify a supported native backend.')
        presentations = {
            'android': ('vulkan', 'sharedTexture'),
            'iOS': ('metal', 'nativeView'),
            'macOS': ('metal', 'nativeView'),
        }
        actual = (scene['backend'].lower(), scene.get('presentation'))
        if actual != presentations.get(response.get('platform')):
            raise ValueError('The city fixture must use native presentation.')
        for size in ('logicalViewport', 'physicalViewport'):
            values = scene.get(size, [])
            if len(values) != 2 or not all(isinstance(v, (int, float)) and math.isfinite(v) and v > 0 for v in values):
                raise ValueError(f'Missing or invalid {size}.')
        checks = scene['checks']
        for field, limit in [('centerPickDistance', 5000), ('cameraDisplacement', 10000)]:
            value = checks.get(field)
            if not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value < limit:
                raise ValueError(f'Failed {field}.')
        for field in ('visibleTiles', 'tilePayloadBytes', 'effects', 'sourceCredits'):
            if not isinstance(checks.get(field), int) or checks[field] <= 0:
                raise ValueError(f'Missing {field}.')
        if checks.get('readbackBytes') != 0:
            raise ValueError('The native city fixture used pixel readback.')
        if scene['inputs'].get('cloudCoverage') is not None and checks.get('cloudHistoryFrames', 0) < 16:
            raise ValueError('Cloud history has not completed a Bayer cycle.')
    if response.get('passed'):
        if seen != {expected} or response.get('cleanup') != 'passed':
            raise ValueError('A passing run requires the scene and cleanup checks.')
        diagnostics = response.get('diagnostics', {})
        names = ['sessions', 'renderers', 'retiring', 'readbackBytes']
        names.append('surfaces' if response.get('platform') == 'android' else 'heldDrawables')
        if any(diagnostics.get(name) != 0 for name in names):
            raise ValueError('Native cleanup is missing or nonzero.')
    return response


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def run(args):
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError('Choose an empty output directory to preserve earlier runs.')
    restored = 0
    try:
        qualified = qualify(args)
    finally:
        if args.leave_test_app:
            state = {'status': 'test app retained'}
            print('Test app retained. Physical taps and gestures are disabled; '
                  'use the launch command before interacting with Planet.')
        else:
            print('Restoring interactive Planet. See interactive-app.log for progress.', flush=True)
            restored = launch(args, args.output / 'interactive-app.log')
            state = {'status': 'launched' if restored == 0 else 'launch failed',
                     'exitCode': restored}
        write_json(args.output / 'interactive-app.json', state)
        print(json.dumps({'interactiveApp': state}))
    return 0 if qualified == 0 and restored == 0 else 1


def launch(args, log_path=None):
    command = [args.flutter, 'run', '--no-pub', '--no-resident', '-d', args.device,
               '--target=lib/google_tiles_lab.dart',
               f'--dart-define=ZYREN_LAB_CLOUDS={str(PRESETS[args.preset][0] == "clouds").lower()}',
               f'--dart-define-from-file={args.provider_config.resolve()}']
    if args.ios:
        command.append('--publish-port')
    try:
        if log_path is None:
            result = subprocess.run(command, cwd=ROOT / 'examples/planet', check=False)
        else:
            with log_path.open('w') as log:
                result = subprocess.run(command, cwd=ROOT / 'examples/planet',
                                        stdout=log, stderr=subprocess.STDOUT, check=False)
        return result.returncode
    except OSError as error:
        print(f'Could not launch interactive Planet: {error}')
        return 1


def qualify(args):
    revision, _ = catalog()
    before = snapshot()
    command = [args.flutter, 'drive', '--no-pub', '-d', args.device,
               '--driver=test_driver/qualification.dart',
               '--target=integration_test/google_tiles_test.dart',
               f'--dart-define=ZYREN_STORY_PRESET={args.preset}',
               f'--dart-define=ZYREN_LAB_CLOUDS={str(PRESETS[args.preset][0] == "clouds").lower()}',
               f'--dart-define-from-file={args.provider_config.resolve()}']
    if args.device != 'macos':
        command.append('--keep-app-running')
    if args.ios:
        command.append('--publish-port')
    env = dict(os.environ, ZYREN_QUALIFICATION_OUTPUT=str((args.output / 'response.json').resolve()))
    started = time.time()
    with (args.output / 'command.log').open('w') as log:
        result = subprocess.run(command, cwd=ROOT / 'examples/planet', env=env,
                                stdout=log, stderr=subprocess.STDOUT, check=False)
    after = snapshot()
    response, error = None, None
    try:
        response = validate_response(json.loads((args.output / 'response.json').read_text()),
                                     preset_identity(args.preset))
    except (OSError, ValueError, KeyError, TypeError) as failure:
        error = str(failure)
    qualified = (result.returncode == 0 and error is None and response['passed']
                 and before['digest'] == after['digest'])
    record = {
        'schema': 1, 'sourceRevision': revision, 'story': preset_identity(args.preset),
        'device': args.device, 'startedUnix': started, 'elapsedSeconds': time.time() - started,
        'command': [value if not value.startswith('--dart-define-from-file=')
                    else '--dart-define-from-file=<private configuration>' for value in command],
        'exitCode': result.returncode, 'before': before, 'after': after,
        'sourceUnchanged': before['digest'] == after['digest'],
        'response': response, 'responseError': error, 'qualified': qualified,
        'logSha256': hashlib.sha256((args.output / 'command.log').read_bytes()).hexdigest(),
        'comparison': 'not run',
    }
    write_json(args.output / 'evidence.json', record)
    print(json.dumps({key: record[key] for key in ('story', 'exitCode', 'sourceUnchanged', 'qualified', 'responseError')}))
    return 0 if qualified else 1


def report(args):
    revision, cases = catalog()
    for path in args.evidence:
        evidence = json.loads(path.read_text())
        if evidence.get('sourceRevision') != revision or evidence.get('story') not in cases:
            raise ValueError(f'Unknown source revision or story in {path}.')
        response = evidence.get('response')
        if response is not None:
            validate_response(response, evidence['story'])
        qualified = bool(response and response.get('passed') and evidence.get('exitCode') == 0
                         and evidence.get('sourceUnchanged') is True
                         and evidence['before']['digest'] == evidence['after']['digest'])
        case = cases[evidence['story']]
        case['runs'].append({'evidence': str(path.resolve()), 'qualified': qualified,
                             'platform': response.get('platform') if response else None,
                             'codeRevision': evidence['before']['head']})
        if qualified:
            case['rendering'] = 'passed'
    output = {'schema': 1, 'sourceRevision': revision, 'caseCount': len(cases),
              'registeredScenes': len(PRESETS),
              'renderedScenes': sum(case['rendering'] == 'passed' for case in cases.values()),
              'comparedScenes': 0, 'stories': list(cases.values())}
    write_json(args.output, output)
    print(json.dumps({key: output[key] for key in ('caseCount', 'registeredScenes', 'renderedScenes', 'comparedScenes')}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('list')
    runner = commands.add_parser('run')
    launcher = commands.add_parser('launch', help='Restore the normal interactive Planet app.')
    for command in (runner, launcher):
        command.add_argument('--preset', choices=PRESETS, required=True)
        command.add_argument('--device', required=True)
        command.add_argument('--ios', action='store_true')
        command.add_argument('--flutter', default='flutter')
        command.add_argument('--provider-config', type=Path, required=True)
    runner.add_argument('--output', type=Path, required=True)
    runner.add_argument('--leave-test-app', action='store_true',
                        help='Skip interactive restoration when batching tests. '
                             'The retained test app ignores physical input.')
    reporter = commands.add_parser('report')
    reporter.add_argument('--output', type=Path, required=True)
    reporter.add_argument('evidence', nargs='*', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'list':
            for key, case in catalog()[1].items():
                print(f'{key}\t{case["implementation"]}')
            return 0
        return {'run': run, 'launch': launch, 'report': report}[args.action](args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    raise SystemExit(main())
