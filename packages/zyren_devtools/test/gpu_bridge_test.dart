import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_devtools/gpu_bridge.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_native/zyren_native.dart';
import '../../zyren/test/support/fakes.dart';

Future<int> requestStatus(
  Uri endpoint,
  String token, {
  String? origin,
  String body = '{}',
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(endpoint);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (origin != null) request.headers.set('origin', origin);
    request.write(body);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

class _DelayedBackend implements RenderBackend, GpuDiagnosticsBackend {
  final entered = Completer<void>();
  final result = Completer<GpuInspection>();
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'delayed',
    features: {},
    limits: DeviceLimits(maxTextureDimension2D: 32, maxGeometryBytes: 32),
  );
  @override
  Future<GpuInspection> inspectGpu({int allocationLimit = 128}) {
    if (!entered.isCompleted) entered.complete();
    return result.future;
  }

  @override
  Future<FrameOutput> render(FrameSubmission submission) =>
      throw UnsupportedError('No rendering in this test.');
  @override
  Future<void> close() async {}
}

void main() {
  test(
    'bridge bounds concurrent queries and closes during pending inspection',
    () async {
      final backend = _DelayedBackend();
      final bridge = GpuInspectionBridge();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [SceneDevtoolsPlugin(), bridge],
      );
      final client = GpuInspectionClient(
        endpoint: bridge.endpoint,
        sessionToken: bridge.sessionToken,
      );
      final pending = client.inspectGpu();
      final rejected = expectLater(
        pending,
        throwsA(
          anyOf(
            isA<StateError>(),
            isA<HttpException>(),
            isA<SocketException>(),
          ),
        ),
      );
      try {
        await backend.entered.future;
        expect(
          await requestStatus(bridge.endpoint, bridge.sessionToken),
          HttpStatus.tooManyRequests,
        );
        await engine.dispose();
        backend.result.complete(
          GpuInspection(
            deviceAllocationSource: 'unavailable',
            registryPayloadBytes: 0,
            totalAllocations: 0,
            allocations: [],
          ),
        );
        await rejected;
        expect(() => bridge.endpoint, throwsStateError);
      } finally {
        client.close();
        if (!backend.result.isCompleted) {
          backend.result.completeError(StateError('Test closed.'));
        }
        await engine.dispose();
      }
    },
  );
  test(
    'bridge is opt-in, validates access and closes with attachment',
    () async {
      final bridge = GpuInspectionBridge();
      expect(() => bridge.endpoint, throwsStateError);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [bridge, SceneDevtoolsPlugin()],
      );
      final endpoint = bridge.endpoint;
      final token = bridge.sessionToken;
      final client = GpuInspectionClient(
        endpoint: endpoint,
        sessionToken: token,
      );
      try {
        expect(endpoint.host, '127.0.0.1');
        expect(await client.inspectGpu(), {
          'available': false,
          'reason': 'backendUnsupported',
        });
        expect(await requestStatus(endpoint, 'wrong'), HttpStatus.forbidden);
        expect(
          await requestStatus(endpoint, token, origin: 'http://localhost'),
          HttpStatus.forbidden,
        );
        expect(
          await requestStatus(endpoint, token, body: '{'),
          HttpStatus.badRequest,
        );
        expect(
          await requestStatus(endpoint, token, body: '{"allocationLimit":257}'),
          HttpStatus.badRequest,
        );
        expect(
          await requestStatus(endpoint, token, body: 'x' * 9000),
          HttpStatus.requestEntityTooLarge,
        );
        await expectLater(
          client.inspectGpu(allocationLimit: 0),
          throwsRangeError,
        );
      } finally {
        await engine.dispose();
        client.close();
      }
      expect(() => bridge.endpoint, throwsStateError);
      expect(() => bridge.sessionToken, throwsStateError);
      await expectLater(client.inspectGpu(), throwsStateError);
      final probe = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      try {
        await expectLater(
          probe.getUrl(endpoint),
          throwsA(isA<SocketException>()),
        );
      } finally {
        probe.close(force: true);
      }
      for (final url in [
        'http://localhost:123/gpu',
        'https://127.0.0.1/gpu',
        'http://127.0.0.1/gpu?token=x',
        'http://example.com/gpu',
      ]) {
        expect(
          () => GpuInspectionClient(
            endpoint: Uri.parse(url),
            sessionToken: token,
          ),
          throwsArgumentError,
        );
      }
    },
  );
  test(
    'remote CLI and MCP inspect the running native host and see allocation cleanup',
    () async {
      final backend = await NativeBackend.create();
      final bridge = GpuInspectionBridge();
      final engine = await SceneEngine.create(
        scene: Scene()..add(Mesh(BoxGeometry(), UnlitMaterial())),
        camera: PerspectiveCamera()..position = const Vec3(0, 0, 4),
        backendFactory: () async => backend,
        plugins: [SceneDevtoolsPlugin(), bridge],
      );
      final scope = backend.createResourceScope();
      final client = GpuInspectionClient(
        endpoint: bridge.endpoint,
        sessionToken: bridge.sessionToken,
      );
      try {
        await engine.render(elapsed: Duration.zero, width: 32, height: 32);
        await engine.render(
          elapsed: const Duration(milliseconds: 16),
          width: 32,
          height: 32,
        );
        final initial = await client.inspectGpu();
        await scope.createBuffer(
          BufferDescriptor(size: 64, usage: {BufferUsage.copyDestination}),
        );
        var workspace = Directory.current;
        while (!File(
          '${workspace.path}/packages/zyren_devtools/example/gpu_inspect.dart',
        ).existsSync()) {
          final parent = workspace.parent;
          if (parent.path == workspace.path) {
            throw StateError('Workspace not found.');
          }
          workspace = parent;
        }
        final script =
            '${workspace.path}/packages/zyren_devtools/example/gpu_inspect.dart';
        final environment = {
          'ZYREN_GPU_ENDPOINT': bridge.endpoint.toString(),
          'ZYREN_GPU_SESSION_TOKEN': bridge.sessionToken,
        };
        final cli = await Process.run(
          Platform.resolvedExecutable,
          ['run', script, '--remote'],
          environment: environment,
          workingDirectory: workspace.path,
        );
        expect(cli.exitCode, 0, reason: cli.stderr.toString());
        final remote = jsonDecode(cli.stdout as String) as Map;
        expect(remote['submittedFrames'], 2);
        expect(
          remote['registryPayloadBytes'],
          (initial['registryPayloadBytes'] as int) + 64,
        );
        expect(
          remote['totalAllocations'],
          (initial['totalAllocations'] as int) + 1,
        );
        expect(remote['residentBytes'], isNull);
        await scope.close();
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['run', script, '--remote', '--mcp'],
          environment: environment,
          workingDirectory: workspace.path,
        );
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}),
        );
        process.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {'name': 'zyren_gpu_inspect', 'arguments': {}},
          }),
        );
        await process.stdin.close();
        expect(await process.exitCode, 0, reason: await stderr);
        final replies = const LineSplitter()
            .convert(await stdout)
            .map((line) => jsonDecode(line) as Map)
            .toList();
        expect(replies.map((r) => r['id']), [1, 2]);
        final result =
            jsonDecode(replies.last['result']['content'][0]['text'] as String)
                as Map;
        expect(result['registryPayloadBytes'], initial['registryPayloadBytes']);
        expect(result['submittedFrames'], 2);
        if (backend.capabilities.backend == 'Metal') {
          expect(result['lastSubmissionGpuTimeNs'], greaterThan(0));
          expect(result['deviceAllocatedBytes'], greaterThan(0));
        }
      } finally {
        client.close();
        await engine.dispose();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
