"""Exercise the existing CLI MCP bridge against the native integration test."""
import argparse
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--log', required=True)
parser.add_argument('--dart', required=True)
parser.add_argument('--evidence', required=True)
parser.add_argument('--package-config')
parser.add_argument('--cli')
parser.add_argument('--shared-source-revision')
args = parser.parse_args()
root = Path(__file__).resolve().parents[5]
cli = Path(args.cli) if args.cli else root / 'packages/zyren_devtools/bin/zyren.dart'
deadline = time.monotonic() + 300
rendezvous = None
while time.monotonic() < deadline:
    content = Path(args.log).read_text(errors='replace') if Path(args.log).exists() else ''
    match = re.search(r'ZYREN_COLLABORATION_BRIDGE_FILE=([^\r\n]+)', content)
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
process = subprocess.Popen([args.dart, *(['--packages=' + args.package_config] if args.package_config else []), str(cli), 'mcp'], stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
    env={**os.environ, 'ZYREN_DEVTOOLS_ENDPOINT': config['endpoint'],
         'ZYREN_DEVTOOLS_TOKEN': config['token'], 'ZYREN_AGENT_TOOLS': '1'})
sequence = 0

def call(method, params=None):
    global sequence
    sequence += 1
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': sequence,
        'method': method, **({'params': params} if params is not None else {})}) + '\n')
    process.stdin.flush()
    if not select.select([process.stdout], [], [], 20)[0]:
        raise TimeoutError('MCP response timed out.')
    line = process.stdout.readline()
    if not line:
        raise RuntimeError('MCP process closed unexpectedly.')
    result = json.loads(line)
    assert result['id'] == sequence and 'error' not in result, result
    return result['result']

def tool(name, arguments):
    return call('tools/call', {'name': name, 'arguments': arguments})

def query(provider, tool_name, arguments=None):
    result = tool('agent_query', {'providerId': provider, 'instanceId': 'main',
        'tool': tool_name, 'arguments': arguments or {}})
    assert not result['isError'], result
    return result['structuredContent']['agentResult']

def command(tool_name, arguments, revision, key):
    return tool('agent_command', {'providerId': 'zyren.collaboration', 'instanceId': 'main',
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
    renderer = tool('get_renderer_capabilities', {})['structuredContent']
    context = query('zyren.viewport', 'context')
    pick = query('zyren.viewport', 'pick', config['point'])
    hit = pick['data']['hits'][0]
    assert hit['object']['runtimeId'] == config['runtimeId'], hit
    assert hit['renderedPixelVisibility'] == 'unknown'
    state = query('zyren.collaboration', 'state')
    revision = state['revision']
    hidden = command('set_visibility', {'source': 'demo-box@1', 'key': 'housing', 'visible': False}, revision, 'mcp-hide')
    assert not hidden['isError'], hidden
    retry = command('set_visibility', {'source': 'demo-box@1', 'key': 'housing', 'visible': False}, revision, 'mcp-hide')
    assert hidden == retry
    stale = command('set_visibility', {'source': 'demo-box@1', 'key': 'housing', 'visible': True}, revision, 'mcp-stale')
    assert stale['isError'] and stale['structuredContent']['agentResult']['status'] == 'stale'
    committed = hidden['structuredContent']['agentResult']['data']['committedRevision']
    state = query('zyren.collaboration', 'state')
    undo = command('undo', {'revision': committed}, state['revision'], 'mcp-undo')
    assert not undo['isError'], undo
    presence = query('zyren.collaboration', 'presence')
    assert len(presence['data']['participants']) == 2
    outbox = query('zyren.collaboration', 'offline_state')
    assert outbox['data']['pending'] == []
    state = query('zyren.collaboration', 'state')
    evidence = {'ok': True, 'sharedSourceRevision': args.shared_source_revision, 'transport': 'external CLI stdio MCP to authenticated native host loopback',
        'providerIds': [p['providerId'] for p in discovery['providers']],
        'renderer': renderer, 'viewport': context, 'hit': hit, 'finalState': state, 'presence': presence, 'outbox': outbox,
        'checks': ['preserved read-only annotations', 'discovery', 'native viewport context',
            'rich CPU triangle pick', 'scoped visibility command', 'conditional shared undo', 'presence', 'durable outbox', 'exact retry', 'stale rejection']}
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
