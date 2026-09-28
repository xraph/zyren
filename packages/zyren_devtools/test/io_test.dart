import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:zyren/zyren.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/io.dart';
import 'package:test/test.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  late String cliPath;
  setUpAll(() async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:zyren_devtools/zyren_devtools.dart'),
    );
    cliPath = File.fromUri(library!.resolve('../bin/zyren.dart')).path;
  });
  late Scene scene;
  late SceneEngine engine;
  late DevtoolsServer server;
  late DevtoolsClient client;
  setUp(() async {
    scene = Scene()
      ..add(Mesh(BoxGeometry(), UnlitMaterial(), name: 'Live cube'));
    final inspector = SceneDevtoolsPlugin();
    engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [inspector],
    );
    server = await DevtoolsServer.start(SceneDiagnostics(inspector));
    client = DevtoolsClient(endpoint: server.endpoint, token: server.token);
  });
  tearDown(() async {
    client.close();
    await server.close();
    await engine.dispose();
  });

  test(
    'loopback bridge reads live changes and rejects bad credentials and browser origins',
    () async {
      expect(server.endpoint.host, '127.0.0.1');
      final before = await client.call('inspect_scene');
      scene.add(Group(name: 'New group'));
      expect((await client.call('inspect_scene'))['totalNodes'], 2);
      expect(before['totalNodes'], 1);
      final bad = DevtoolsClient(endpoint: server.endpoint, token: 'wrong');
      addTearDown(bad.close);
      await expectLater(
        bad.call('inspect_scene'),
        throwsA(
          isA<DiagnosticException>().having(
            (e) => e.code,
            'code',
            'unauthorized',
          ),
        ),
      );
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final request = await http.postUrl(server.endpoint);
      request.headers.set('Authorization', 'Bearer ${server.token}');
      request.headers.set('Origin', 'https://example.com');
      final response = await request.close();
      expect(response.statusCode, 403);
      await response.drain<void>();
    },
  );

  test(
    'bridge enforces body limits, propagates tool errors and closes sockets',
    () async {
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final request = await http.postUrl(server.endpoint);
      request.headers.set('Authorization', 'Bearer ${server.token}');
      request.write('x' * 17000);
      final response = await request.close();
      expect(response.statusCode, 413);
      await response.drain<void>();
      await expectLater(
        client.call('inspect_object', {'id': 900}),
        throwsA(
          isA<DiagnosticException>().having(
            (e) => e.code,
            'code',
            'objectNotFound',
          ),
        ),
      );
      await server.close();
      await expectLater(
        client.call('inspect_scene'),
        throwsA(
          isA<DiagnosticException>().having(
            (e) => e.code,
            'code',
            'connectionFailed',
          ),
        ),
      );
    },
  );

  test(
    'CLI reads a real bridge and exits nonzero for a bad operation',
    () async {
      final cli = cliPath;
      final environment = {
        'ZYREN_DEVTOOLS_ENDPOINT': server.endpoint.toString(),
        'ZYREN_DEVTOOLS_TOKEN': server.token,
      };
      final result = await Process.run(Platform.resolvedExecutable, [
        cli,
        'inspect_scene',
      ], environment: environment);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        jsonDecode(result.stdout as String)['nodes'][0]['name'],
        'Live cube',
      );
      final error = await Process.run(Platform.resolvedExecutable, [
        cli,
        'inspect_object',
        '{"id":99}',
      ], environment: environment);
      expect(error.exitCode, 1);
      expect(
        jsonDecode(error.stderr as String)['error']['code'],
        'objectNotFound',
      );
    },
  );

  test('MCP negotiates, lists and invokes tools over a real process', () async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [cliPath, 'mcp'],
      environment: {
        'ZYREN_DEVTOOLS_ENDPOINT': server.endpoint.toString(),
        'ZYREN_DEVTOOLS_TOKEN': server.token,
      },
    );
    addTearDown(() {
      process.kill();
    });
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final responses = <Map<String, dynamic>>[];
    final done = lines.forEach(
      (line) => responses.add(jsonDecode(line) as Map<String, dynamic>),
    );
    void send(Object value) => process.stdin.writeln(jsonEncode(value));
    send({'jsonrpc': '2.0', 'id': 0, 'method': 'tools/list'});
    send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-11-25',
        'capabilities': {},
        'clientInfo': {'name': 'test', 'version': '1'},
      },
    });
    send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    send({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': 'inspect_scene', 'arguments': {}},
    });
    send({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'tools/call',
      'params': {
        'name': 'inspect_object',
        'arguments': {'id': 99},
      },
    });
    process.stdin.writeln('{bad json');
    send({'jsonrpc': '2.0', 'id': 5, 'method': 'ping'});
    await process.stdin.close();
    await done;
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    expect(responses.map((r) => r['id']), [0, 1, 2, 3, 4, null, 5]);
    expect(responses[0]['error']['code'], -32002);
    expect(responses[1]['result']['protocolVersion'], '2025-11-25');
    expect(responses[2]['result']['tools'], hasLength(7));
    expect(
      responses[3]['result']['structuredContent']['nodes'][0]['name'],
      'Live cube',
    );
    expect(responses[4]['result']['isError'], true);
    expect(responses[5]['error']['code'], -32700);
  });

  test('client refuses remote destinations before sending its token', () {
    expect(
      () => DevtoolsClient(
        endpoint: Uri.parse('https://example.com/call'),
        token: 'secret',
      ),
      throwsArgumentError,
    );
  });
}
