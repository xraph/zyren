"""Probe a running lab through the existing stdio MCP to loopback bridge."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

rendezvous = Path(sys.argv[1])
evidence = Path(sys.argv[2])
config = json.loads(rendezvous.read_text())
env = {**os.environ, 'ZYREN_AGENT_TOOLS': '1',
       'ZYREN_DEVTOOLS_ENDPOINT': config['endpoint'],
       'ZYREN_DEVTOOLS_TOKEN': config['token']}
dart = os.environ.get('DART', 'dart')
child = subprocess.Popen([dart, 'run', 'zyren_devtools:zyren', 'mcp'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, env=env)
records = []
sequence = 0

def request(method, params):
    global sequence
    sequence += 1
    child.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': sequence,
                                'method': method, 'params': params}) + '\n')
    child.stdin.flush()
    while True:
        line = child.stdout.readline()
        if not line:
            raise RuntimeError('MCP process closed before a response')
        try:
            response = json.loads(line)
        except json.JSONDecodeError:
            continue
        if response.get('id') == sequence:
            assert 'error' not in response, response
            records.append({'method': method, 'params': params, 'result': response['result']})
            return response['result']

def call(name, arguments):
    result = request('tools/call', {'name': name, 'arguments': arguments})
    return json.loads(result['content'][0]['text'])

def query(provider, instance, tool, arguments=None):
    return call('agent_query', {'providerId': provider, 'instanceId': instance,
                'tool': tool, 'arguments': arguments or {}})['agentResult']

def command(provider, instance, tool, revision, arguments):
    result = call('agent_command', {'providerId': provider, 'instanceId': instance,
                  'tool': tool, 'expectedRevision': revision,
                  'idempotencyKey': f'probe-{sequence}', 'arguments': arguments})['agentResult']
    assert result['status'] == 'ok', result
    return result

try:
    request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                         'clientInfo': {'name': 'smaller-lab-probe', 'version': '1'}})
    child.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
    child.stdin.flush()
    request('tools/list', {})
    call('agent_discover', {})
    view = query('zyren.viewport', 'view', 'context')
    assert view['data']['frameCorrelation'] == 'matches-current-state', view
    frame = view['data']['presentedFrame']['id']
    hit = query('zyren.viewport', 'view', 'pick', {'x': .5, 'y': .5,
                'coordinateSpace': 'normalized', 'expectedFrameId': frame})
    assert hit['data']['hits'][0]['object']['metadata']['sourceId'] == 'body', hit
    state = query('zyren_configurator', 'config', 'inspect')
    command('zyren_configurator', 'config', 'apply', state['revision'],
            {'choices': [{'slot': 'finish', 'option': 'blue'}]})
    for _ in range(30):
        view = query('zyren.viewport', 'view', 'context')
        if view['data']['frameCorrelation'] == 'matches-current-state' and view['data']['presentedFrame']['id'] != frame:
            break
        time.sleep(.1)
    assert view['data']['presentedFrame']['id'] != frame, view
    state = query('zyren_effects', 'effects', 'inspect')
    command('zyren_effects', 'effects', 'chain', state['revision'], {'dithering': False, 'smaa': 'off'})
    state = query('zyren_effects', 'effects', 'inspect')
    assert state['data']['chain']['dithering'] is False
    query('zyren_configurator', 'config', 'viewpoints')
    query('zyren_audio', 'audio', 'inspect')
    evidence.write_text(json.dumps({'ok': True, 'calls': records}, indent=2))
    print(json.dumps({'ok': True, 'calls': len(records), 'evidence': str(evidence)}))
finally:
    child.stdin.close()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
