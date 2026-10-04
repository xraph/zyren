#!/usr/bin/env python3
"""Run Flutter for Planet with its private provider configuration."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROVIDER_KEYS = ('ZYREN_GOOGLE_MAPS_KEY', 'ZYREN_CESIUM_ION_TOKEN')


def flutter_command(args):
    command = list(args.command)
    if not command or command[0] not in ('run', 'build', 'drive', 'test'):
        raise ValueError('Supply a Flutter run, build, drive or test command.')
    for index, value in enumerate(command):
        if value.startswith('--dart-define-from-file'):
            raise ValueError('Use --provider-config before the Flutter command.')
        define = (command[index + 1] if value == '--dart-define' and
                  index + 1 < len(command) else value.removeprefix('--dart-define='))
        if define.partition('=')[0] in PROVIDER_KEYS:
            raise ValueError('Keep provider credentials in the private config file.')
    if not args.offline:
        config = args.provider_config.expanduser().resolve()
        try:
            data = json.loads(config.read_text())
        except (OSError, ValueError):
            raise ValueError('Provider config is missing or invalid. Set --provider-config '
                             'or ZYREN_PROVIDER_CONFIG; use --offline for local scenes only.') from None
        if not isinstance(data, dict) or not any(
                isinstance(data.get(key), str) and data[key].strip() for key in PROVIDER_KEYS):
            raise ValueError('Provider config needs ZYREN_CESIUM_ION_TOKEN or ZYREN_GOOGLE_MAPS_KEY.')
        command.append(f'--dart-define-from-file={config}')
    flutter = [args.flutter] if args.flutter else ['fvm', 'flutter']
    return flutter + command


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', help='Flutter executable; defaults to fvm flutter.')
    parser.add_argument('--provider-config', type=Path, default=Path(os.environ.get(
        'ZYREN_PROVIDER_CONFIG', Path.home() / '.config/zyren/planet-provider.json')))
    parser.add_argument('--offline', action='store_true',
                        help='Build local scenes without live provider access.')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        command = flutter_command(args)
    except ValueError as error:
        parser.error(str(error))
    try:
        return subprocess.run(command, cwd=ROOT / 'examples/planet', check=False).returncode
    except OSError:
        print('Could not run Flutter. Set --flutter to the workspace SDK executable.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
