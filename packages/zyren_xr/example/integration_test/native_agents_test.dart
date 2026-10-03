import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren/zyren.dart' as z;
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_xr/agents.dart';
import 'package:zyren_xr/flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native rich hit and placement over shared MCP and HTTP', (
    tester,
  ) async {
    Future<T> native<T>(Future<T> Function() action) async {
      Object? failure;
      StackTrace? trace;
      final result = await tester.runAsync(() async {
        try {
          return await action();
        } catch (error, stack) {
          failure = error;
          trace = stack;
          debugPrint('XR native failure: $error');
          return null;
        }
      });
      if (failure != null) Error.throwWithStackTrace(failure!, trace!);
      return result as T;
    }

    const transport = MethodChannelXrTransport();
    final session = await native(() => XrSession.create(transport));
    XrPresentationController? presenter;
    DevtoolsServer? server;
    DevtoolsClient? client;
    _Mcp? mcp;
    AgentRegistry? registry;
    XrAgentProvider? provider;
    XrSceneBindings? bindings;
    try {
      const depth = bool.fromEnvironment('XR_TEST_DEPTH');
      await native(
        () => session.start(
          configuration: const XrConfiguration(
            requireCameraPresentation: true,
            requireDepthOcclusion: depth,
          ),
        ),
      );
      final p = await native(
        () => XrPresentationController.create(session: session),
      );
      presenter = p;
      final scene = z.Scene()
        ..background = null
        ..backgroundOpacity = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: XrCameraView(controller: p)),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await native(() async {
        Future<XrCalibration> frame() async {
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (true) {
            try {
              return await p.render(scene);
            } on XrException catch (error) {
              if (!{
                    'trackingUnavailable',
                    'frameDeferred',
                    'depthUnavailable',
                    'staleDepth',
                  }.contains(error.code) ||
                  DateTime.now().isAfter(deadline)) {
                rethrow;
              }
              await Future<void>.delayed(const Duration(milliseconds: 80));
            }
          }
        }

        await frame();
        final capabilities = await XrSession.capabilities(transport);
        registry = AgentRegistry(grantedScopes: {'xr.place'});
        provider = XrAgentProvider(
          instanceId: 'native-probe',
          commands: XrPlacementCommands(session),
          deviceCapabilities: capabilities,
          allowPlacement: true,
          raycast: p.raycast,
          view: () {
            final c = p.presentedCalibration!;
            return XrViewBinding(
              sceneId: 'native-probe',
              documentId: 'unsaved-probe',
              viewportId: 'camera',
              cameraId: 'native-camera',
              sceneRevision: scene.revision,
              logicalRect: [0, 0, c.logicalWidth, c.logicalHeight],
              devicePixelRatio: c.devicePixelRatio,
              sceneFromSession: XrPose.identity(),
              presentedFrameId: c.frameId,
              presentedSceneRevision: p.presentedSceneRevision,
              calibration: c,
            );
          },
        );
        registry!.register(provider!);
        server = await DevtoolsServer.start(
          SceneDiagnostics(SceneDevtoolsPlugin()),
          agents: registry,
        );
        client = DevtoolsClient(
          endpoint: server!.endpoint,
          token: server!.token,
        );
        mcp = _Mcp(client!);
        await mcp!.initialize();
        final tools = (await mcp!.request('tools/list'))['tools'] as List;
        expect(tools.any((t) => t['name'] == 'agent_query'), isTrue);
        final discovery = await mcp!.call('agent_discover', {});
        expect((discovery['agentDiscovery'] as Map)['providers'], isNotEmpty);
        Future<Map> query(
          String tool, [
          Map<String, Object?> args = const {},
        ]) async =>
            (await mcp!.call('agent_query', {
                  'providerId': 'zyren.xr',
                  'instanceId': 'native-probe',
                  'tool': tool,
                  'arguments': args,
                }))['agentResult']
                as Map;
        Future<Map> command(
          String tool,
          Map<String, Object?> args,
          int revision,
          String key,
        ) async =>
            (await mcp!.call('agent_command', {
                  'providerId': 'zyren.xr',
                  'instanceId': 'native-probe',
                  'tool': tool,
                  'arguments': args,
                  'expectedRevision': revision,
                  'idempotencyKey': key,
                }))['agentResult']
                as Map;
        final inspected = await query('inspect');
        expect(inspected['status'], 'ok');
        expect(inspected['data']['view']['xrCameraPresentation'], true);
        Map? selected;
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (selected == null && DateTime.now().isBefore(deadline)) {
          final c = await frame();
          for (final point in [
            [.5, .5],
            [.5, .7],
            [.3, .7],
            [.7, .7],
          ]) {
            final hits = await query('screen_raycast', {
              'x': c.logicalWidth * point[0],
              'y': c.logicalHeight * point[1],
            });
            if (hits['status'] == 'ok' &&
                (hits['data']['hits'] as List).isNotEmpty) {
              selected = (hits['data']['hits'] as List).first as Map;
              break;
            }
          }
          if (selected == null) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
        expect(
          selected,
          isNotNull,
          reason:
              'Move the camera toward a textured surface until a native plane is detected.',
        );
        final hit = selected!;
        expect(hit['pixelVisibility'], 'unknown');
        expect(hit['sourceId'], isNull);
        final args = <String, Object?>{
          'hitToken': hit['hitToken'],
          'sceneRevision': scene.revision,
          'viewportId': 'camera',
        };
        final readOnly = await query('place_hit', args);
        expect(readOnly['status'], 'denied');
        final placed = await command('place_hit', args, 0, 'native-hit');
        expect(placed['status'], 'ok', reason: '$placed');
        final retry = await command('place_hit', args, 0, 'native-hit');
        expect(retry['status'], 'ok');
        final anchor = placed['data']['anchorId'] as String;
        var snapshot = await session.snapshot();
        for (
          var i = 0;
          i < 30 && !snapshot.frame!.anchors.any((a) => a.id == anchor);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          snapshot = await session.snapshot();
        }
        expect(
          snapshot.frame!.anchors.where((a) => a.id == anchor),
          hasLength(1),
        );
        if (hit['planeId'] case final String planeId) {
          final geometry = await session.planeGeometry(
            planeId,
            expectedRevision: snapshot.revision,
          );
          expect(geometry.vertices, isNotEmpty);
        }
        final root = z.Group();
        scene.add(root);
        bindings = XrSceneBindings(
          sessionId: session.id,
          root: root,
          originEpoch: snapshot.originEpoch,
        );
        final cube = z.Mesh(
          z.BoxGeometry(width: .1, height: .1, depth: .1),
          z.UnlitMaterial(),
        );
        final binding = bindings!.bind(
          anchorId: anchor,
          object: cube,
          sourceId: 'probe:cube-template',
        );
        bindings!.update(snapshot);
        expect(binding.tracked, true);
        expect(binding.runtimeObjectId, cube.id);
        await frame();
        expect(p.diagnostics!['cameraReadbackBytes'], 0);
        expect(p.diagnostics!['nativeReadbackBytes'], 0);
        expect(p.presentedCalibration!.depthEnabled, depth);
        final undo = await command(
          'undo_placement',
          {'sceneRevision': scene.revision, 'viewportId': 'camera'},
          1,
          'native-undo',
        );
        expect(undo['status'], 'ok', reason: '$undo');
        final beforeReset = await session.snapshot();
        final replace = await command(
          'place_anchor',
          {
            'sceneRevision': scene.revision,
            'viewportId': 'camera',
            'sessionRevision': beforeReset.revision,
            'frameTimestamp': beforeReset.frame!.timestamp,
            'transform': (hit['transform'] as List),
          },
          2,
          'before-reset',
        );
        expect(replace['status'], 'ok', reason: '$replace');
        await session.start(
          configuration: const XrConfiguration(
            requireCameraPresentation: true,
            requireDepthOcclusion: depth,
          ),
          resetTracking: true,
        );
        final reset = await session.snapshot();
        bindings!.update(reset);
        expect(reset.originEpoch, greaterThan(snapshot.originEpoch));
        expect(bindings!.bindings, isEmpty);
        await frame();
        var afterReset = await query('inspect');
        if (afterReset['status'] == 'stale')
          afterReset = await query('inspect');
        expect(afterReset['status'], 'ok');
        expect(provider!.commands.canUndo, isFalse);
        final resetUndo = await command(
          'undo_placement',
          {'sceneRevision': scene.revision, 'viewportId': 'camera'},
          provider!.revision,
          'reset-undo',
        );
        expect(resetUndo['status'], 'empty');
        await session.pause();
        await expectLater(p.render(scene), throwsA(isA<XrException>()));
        debugPrint(
          'XR_NATIVE_MCP_PASS ${jsonEncode({'platform': capabilities.platform, 'depthRequested': depth, 'transport': 'shared-mcp-codec-and-authenticated-loopback-http', 'nativePlaneHit': true, 'placementRetryUndoReset': true, 'cameraReadbackBytes': p.diagnostics?['cameraReadbackBytes']})}',
        );
      });
    } finally {
      await native(() async {
        await mcp?.close();
        client?.close();
        await server?.close();
        registry?.dispose();
        provider?.dispose();
        bindings?.dispose();
        await presenter?.close();
        presenter?.dispose();
        await session.dispose();
      });
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

// The production MCP codec and HTTP client run unchanged. Only test stdin/stdout
// are streams because a mobile process cannot spawn a host-side stdio client.
final class _Mcp {
  final _input = StreamController<List<int>>();
  final _pending = <int, Completer<Map>>{};
  late final Future<void> _serving;
  int _id = 0;
  _Mcp(DevtoolsClient client) {
    _serving = serveDevtoolsMcp(
      input: _input.stream,
      call: client.call,
      agentsEnabled: true,
      output: (line) {
        final message = jsonDecode(line) as Map;
        final pending = _pending.remove(message['id']);
        if (message['error'] != null) {
          pending?.completeError(StateError('${message['error']}'));
        } else {
          pending?.complete(message['result'] as Map);
        }
      },
    );
  }
  Future<Map> request(String method, [Map<String, Object?> params = const {}]) {
    final id = ++_id, pending = Completer<Map>();
    _pending[id] = pending;
    _input.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n',
      ),
    );
    return pending.future.timeout(const Duration(seconds: 10));
  }

  Future<void> initialize() async {
    await request('initialize', {
      'protocolVersion': '2025-11-25',
      'capabilities': {},
      'clientInfo': {'name': 'xr-native-probe', 'version': '1'},
    });
    _input.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'})}\n',
      ),
    );
  }

  Future<Map> call(String name, Map<String, Object?> arguments) async =>
      (await request('tools/call', {
            'name': name,
            'arguments': arguments,
          }))['structuredContent']
          as Map;
  Future<void> close() async {
    await _input.close();
    await _serving;
  }
}
