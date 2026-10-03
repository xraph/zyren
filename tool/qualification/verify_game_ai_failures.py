#!/usr/bin/env python3
"""Validate complete failure/recovery cases and reject missing execution evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
REQUIRED_CASES = frozenset(('project.malformed', 'project.oversized', 'prefab.cycle',
    'entity.removed', 'action.stale', 'model.schema', 'model.hash', 'model.operator',
    'sensor.unknown', 'queue.saturated', 'cancellation', 'worker.crash', 'save.failed',
    'renderer.loss', 'editor.conflict', 'leakage.hidden-position',
    'leakage.hearing-uncertainty', 'leakage.stale-nav', 'leakage.teacher-input',
    'leakage.lost-sight', 'leakage.pool-replacement', 'tools.denied', 'tools.retry',
    'tools.cancel', 'tools.dispose'))
NATIVE_CASES = frozenset(('model.schema', 'model.hash', 'model.operator', 'sensor.unknown',
    'cancellation', 'worker.crash', 'renderer.loss', 'leakage.hidden-position',
    'leakage.hearing-uncertainty', 'leakage.stale-nav', 'leakage.pool-replacement'))


def validate(document, root=ROOT, *, release=True):
    errors = []
    root = Path(root).resolve()
    if not isinstance(document, dict) or type(document.get('schemaVersion')) is not int or document.get('schemaVersion') != 1:
        return ['matrix: expected schemaVersion 1']
    cases = document.get('cases')
    if not isinstance(cases, dict):
        return ['matrix: expected cases map']
    for name in sorted(REQUIRED_CASES - cases.keys()):
        errors.append(f'{name}: missing required case')
    for name in sorted(cases.keys() - REQUIRED_CASES):
        errors.append(f'{name}: unknown case')
    for name in sorted(REQUIRED_CASES & cases.keys()):
        row = cases[name]
        def error(message):
            errors.append(f'{name}: {message}')
        if not isinstance(row, dict):
            error('expected case object')
            continue
        for field in ('condition', 'expectedStatus', 'recoveryAction'):
            if not isinstance(row.get(field), str) or not row[field].strip():
                error(f'{field} is required')
        for field in ('preservedIdentities', 'cleanupCounters'):
            keys = row.get(field)
            if not isinstance(keys, list) or not keys or any(not isinstance(k, str) or not k for k in keys):
                error(f'{field} needs named assertions')
        if row.get('status') == 'blocked':
            if not isinstance(row.get('reason'), str) or not row['reason'].strip():
                error('blocked case needs a reason')
            if release:
                error('required case is blocked')
            continue
        if row.get('status') != 'passed':
            error('case is not passed or explicitly blocked')
            continue
        try:
            pin = row['evidence']
            path = pin['path']
            if not isinstance(path, str) or Path(path).is_absolute():
                raise ValueError('receipt path must be repository-relative')
            path = (root / path).resolve()
            if not path.is_relative_to(root):
                raise ValueError('receipt path escapes repository')
            if not isinstance(pin['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', pin['sha256']):
                raise ValueError('receipt needs SHA256 pin')
            content = path.read_bytes()
            if len(content) > 16_777_216 or hashlib.sha256(content).hexdigest() != pin['sha256']:
                raise ValueError('receipt changed or exceeds bound')
            receipt = json.loads(content)
            if type(receipt.get('schemaVersion')) is not int or receipt['schemaVersion'] != 1:
                raise ValueError('receipt version differs')
            result = receipt['cases'][name]
            if result['status'] != 'passed' or result['actualStatus'] != row['expectedStatus']:
                raise ValueError('operation status differs or case skipped')
            execution = result['execution']
            if (type(execution.get('exitCode')) is not int or execution['exitCode'] != 0
                    or not isinstance(execution.get('command'), str) or not execution['command'].strip()
                    or execution.get('kind') not in ('pure', 'native')):
                raise ValueError('successful execution command is missing')
            if name in NATIVE_CASES and execution['kind'] != 'native':
                raise ValueError('lifetime/perception case needs actual native execution')
            if result['recovery'] != {'action': row['recoveryAction'], 'status': 'passed'}:
                raise ValueError('recovery did not pass')
            if result['before'] != result['after']:
                raise ValueError('complete preserved identity receipt changed')
            for key in row['preservedIdentities']:
                if key not in result['before'] or key not in result['after'] or result['before'][key] != result['after'][key]:
                    raise ValueError(f'preserved identity changed: {key}')
            for key in row['cleanupCounters']:
                before = result['cleanupCounters']['before'][key]
                after = result['cleanupCounters']['after'][key]
                if type(before) is not int or type(after) is not int or before < 0 or after != before:
                    raise ValueError(f'cleanup did not return to baseline: {key}')
        except (KeyError, TypeError, ValueError, OSError) as exception:
            error(str(exception))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', nargs='?', type=Path, default=ROOT / 'tool/qualification/game_ai_failure_matrix.json')
    parser.add_argument('--check-schema', action='store_true')
    args = parser.parse_args()
    try:
        errors = validate(json.loads(args.path.read_text()), release=not args.check_schema)
    except (OSError, ValueError, TypeError) as exception:
        errors = [str(exception)]
    print(json.dumps({'status': 'failed' if errors else 'passed',
                      'mode': 'schema' if args.check_schema else 'qualification', 'diagnostics': errors}, indent=2))
    raise SystemExit(bool(errors))


if __name__ == '__main__':
    main()
