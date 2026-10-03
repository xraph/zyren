"""Exercise the existing CLI MCP bridge against the native integration test."""
import argparse
import json
import os
from pathlib import Path
import re
import queue
import threading
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--log', required=True)
parser.add_argument('--dart', required=True)
parser.add_argument('--evidence', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[4]
cli = root / 'packages/zyren_devtools/bin/zyren.dart'
deadline = time.monotonic() + 300
rendezvous = None
while time.monotonic() < deadline:
    content = Path(args.log).read_text(errors='replace') if Path(args.log).exists() else ''
    match = re.search(r'ZYREN_INTERACTION_BRIDGE_FILE=([^\r\n]+)', content)
    if match:
        rendezvous = Path(match.group(1).strip())
        if rendezvous.exists():
            break
    if 'Some tests failed' in content or 'Build process failed' in content:
        raise RuntimeError('Native test failed before opening the bridge.')
    time.sleep(.5)
if rendezvous is None or not rendezvous.exists():
    raise TimeoutError('Native bridge rendezvous did not appear.')
config = json.loads(rendezvous.read_text())
process = subprocess.Popen([args.dart, str(cli), 'mcp'], stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
    env={**os.environ, 'ZYREN_DEVTOOLS_ENDPOINT': config['endpoint'],
         'ZYREN_DEVTOOLS_TOKEN': config['token'], 'ZYREN_AGENT_TOOLS': '1'})
sequence = 0
responses = queue.Queue()
notifications = []
def read_responses():
    for line in process.stdout:
        responses.put(json.loads(line))
threading.Thread(target=read_responses, daemon=True).start()

def call(method, params=None):
    global sequence
    sequence += 1
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': sequence,
        'method': method, **({'params': params} if params is not None else {})}) + '\n')
    process.stdin.flush()
    while True:
        result = responses.get(timeout=20)
        if 'id' not in result:
            notifications.append(result)
            continue
        assert result['id'] == sequence and 'error' not in result, result
        break
    return result['result']

def tool(name, arguments):
    return call('tools/call', {'name': name, 'arguments': arguments})

def query(provider, tool_name, arguments=None):
    result = tool('agent_query', {'providerId': provider, 'instanceId': 'main',
        'tool': tool_name, 'arguments': arguments or {}})
    assert not result['isError'], result
    return result['structuredContent']['agentResult']

def command(tool_name, arguments, revision, key):
    return tool('agent_command', {'providerId': 'zyren.interaction', 'instanceId': 'main',
        'tool': tool_name, 'arguments': arguments, 'expectedRevision': revision,
        'idempotencyKey': key})

try:
    call('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
        'clientInfo': {'name': 'zyren-native-probe', 'version': '1'}})
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
    process.stdin.flush()
    tools = call('tools/list')['tools']
    assert next(t for t in tools if t['name'] == 'inspect_scene')['annotations']['readOnlyHint']
    assert not next(t for t in tools if t['name'] == 'agent_command')['annotations']['readOnlyHint']
    discovery = tool('agent_discover', {})['structuredContent']['agentDiscovery']
    resources = call('resources/list')['resources']
    changes_uri = next(r['uri'] for r in resources if r['name'] == 'agent-changes')
    call('resources/subscribe', {'uri': changes_uri})
    renderer = tool('get_renderer_capabilities', {})['structuredContent']
    context = query('zyren.viewport', 'context')
    pick = query('zyren.viewport', 'pick', config['point'])
    hit = pick['data']['hits'][0]
    assert hit['object']['runtimeId'] == config['runtimeId'], hit
    assert hit['renderedPixelVisibility'] == 'unknown'
    state = query('zyren.interaction', 'state')
    cleared = command('clear_selection', {}, state['revision'], 'mcp-clear')
    assert not cleared['isError'], cleared
    state = query('zyren.interaction', 'state')
    revision = state['revision']
    selected = command('select', {'runtimeId': config['runtimeId']}, revision, 'mcp-select')
    assert not selected['isError'], selected
    retry = command('select', {'runtimeId': config['runtimeId']}, revision, 'mcp-select')
    assert selected == retry
    stale = command('clear_selection', {}, revision, 'mcp-stale')
    assert stale['isError'] and stale['structuredContent']['agentResult']['status'] == 'stale'
    state = query('zyren.interaction', 'state')
    assert state['data']['selectedRuntimeId'] == config['runtimeId']
    viewport_size = context['data']['viewport']
    normalized = query('zyren.viewport', 'pick', {'x': config['point']['x'] / viewport_size['width'],
        'y': config['point']['y'] / viewport_size['height'], 'coordinateSpace': 'normalized'})
    assert normalized['data']['hits'][0]['object']['runtimeId'] == config['runtimeId']
    assert hit['object']['projectedBounds']['status'] == 'ok'
    job = tool('agent_job_start', {'jobId': 'native-read', 'providerId': 'zyren.interaction',
        'instanceId': 'main', 'tool': 'state', 'readOnly': True})['structuredContent']['agentJob']
    for _ in range(10):
        if job['state'] == 'complete': break
        time.sleep(.1)
        job = tool('agent_job_status', {'jobId': 'native-read'})['structuredContent']['agentJob']
    assert job['state'] == 'complete' and job['result']['status'] == 'ok', job
    changes = tool('agent_changes', {})['structuredContent']['agentChanges']
    assert any(e['kind'] == 'job-completed' for e in changes['events'])
    tool('agent_job_release', {'jobId': 'native-read'})
    if not notifications:
        notifications.append(responses.get(timeout=3))
    assert any(n.get('method') == 'notifications/resources/updated' for n in notifications)
    resource = call('resources/read', {'uri': changes_uri})['contents'][0]
    assert json.loads(resource['text'])['events']
    call('resources/unsubscribe', {'uri': changes_uri})
    evidence = {'ok': True, 'transport': 'external CLI stdio MCP to authenticated native host loopback',
        'providerIds': [p['providerId'] for p in discovery['providers']],
        'renderer': renderer, 'viewport': context, 'hit': hit, 'finalState': state,
        'checks': ['preserved read-only annotations', 'discovery', 'native viewport context',
            'rich CPU triangle pick', 'scoped selection command', 'exact retry', 'stale rejection', 'normalized coordinates', 'projected bounds', 'job lifecycle', 'change cursor', 'MCP resource subscription']}
    Path(args.evidence).parent.mkdir(parents=True, exist_ok=True)
    Path(args.evidence).write_text(json.dumps(evidence, indent=2) + '\n')
    Path(str(rendezvous) + '.done').write_text(json.dumps({'ok': True}))
    print('Native MCP probe passed; evidence written without credentials.')
finally:
    process.stdin.close()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
