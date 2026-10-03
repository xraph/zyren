import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_xr/agents.dart';
import 'package:zyren_xr/flutter.dart';

import 'calibration_test.dart' show calibrationMessage;
import 'fixtures.dart';

Map<String, Object?> hitMessage() => {
  'frameId': 1,
  'epoch': 1,
  'frameTimestamp': 12.0,
  'sensorTimestamp': 12.1,
  'sessionRevision': 3,
  'originEpoch': 0,
  'omittedHits': 0,
  'coverage': 'native-plane-geometry-estimate',
  'hits': [
    {
      'planeId': 'plane',
      'transform': XrPose.identity().matrix,
      'distance': 1.0,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'plane geometry rejects malformed bounds and creates shared geometry',
    () {
      final data = <String, Object?>{
        'planeId': 'plane',
        'sessionRevision': 1,
        'frameTimestamp': 12.0,
        'transform': XrPose.identity().matrix,
        'vertices': [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
        'indices': [0, 1, 2],
        'boundary': <double>[],
      };
      final geometry = XrPlaneGeometry.fromMessage(data).toGeometry();
      expect(geometry.vertexCount, 3);
      expect(geometry.normals, [0, 1, 0, 0, 1, 0, 0, 1, 0]);
      expect(
        () => XrPlaneGeometry.fromMessage({
          ...data,
          'indices': [0, 1, 3],
        }),
        throwsFormatException,
      );
      expect(
        () => XrRaycastResult.fromMessage({
          ...hitMessage(),
          'sensorTimestamp': 13.0,
        }),
        throwsFormatException,
      );
    },
  );

  test('raycast binds a native result to the exact presented frame', () async {
    var wrongFrame = false;
    final transport = RecordingTransport()
      ..handler = (method, args) => switch (method) {
        'create' => {'sessionId': 'session-1'},
        'createPresenter' => {'presenterId': 'presenter-1'},
        'acquireFrame' => calibrationMessage(),
        'presentFrame' => {...calibrationMessage(), 'presented': true},
        'raycast' => {...hitMessage(), if (wrongFrame) 'frameId': 2},
        _ => null,
      };
    final session = await XrSession.create(transport);
    final presenter = await XrPresentationController.create(
      session: session,
      transport: transport,
      runtimeToken: 1,
    );
    await expectLater(presenter.raycast(1, 1), throwsA(isA<XrException>()));
    await presenter.render(
      Scene()
        ..background = null
        ..backgroundOpacity = 0,
    );
    expect((await presenter.raycast(100, 200)).hits.single.planeId, 'plane');
    expect(transport.calls.last.$2['expectedRevision'], 3);
    await expectLater(presenter.raycast(300, 200), throwsArgumentError);
    wrongFrame = true;
    await expectLater(presenter.raycast(100, 200), throwsA(isA<XrException>()));
    await presenter.close();
    presenter.dispose();
    await session.dispose();
  });

  test(
    'rich hit uses shared scoped placement and expires after origin mutation',
    () async {
      final transport = RecordingTransport()
        ..current = snapshotMessage(revision: 3);
      final session = await XrSession.create(transport);
      final calibration = XrCalibration.fromMessage(calibrationMessage());
      final view = XrViewBinding(
        sceneId: 'scene',
        documentId: 'doc',
        viewportId: 'view',
        cameraId: 'camera',
        sceneRevision: 2,
        logicalRect: [0, 0, 300, 600],
        devicePixelRatio: 2,
        sceneFromSession: XrPose.identity(),
        presentedFrameId: 1,
        presentedSceneRevision: 2,
        calibration: calibration,
      );
      final commands = XrPlacementCommands(session);
      final provider = XrAgentProvider(
        instanceId: 'test',
        commands: commands,
        deviceCapabilities: XrCapabilities.fromMessage(capabilitiesMessage()),
        view: () => view,
        allowPlacement: true,
        raycast: (_, _) async => XrRaycastResult.fromMessage(hitMessage()),
      );
      final registry = AgentRegistry(grantedScopes: {'xr.place'})
        ..register(provider);
      Future<AgentResult> query() => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'screen_raycast',
        arguments: {'x': 100.0, 'y': 200.0},
      );
      final result = await query();
      expect(result.status, AgentStatus.ok, reason: result.message);
      final hit = (result.data['hits'] as List).single as Map;
      expect(hit['pixelVisibility'], 'unknown');
      expect(hit['sourceId'], isNull);
      final args = <String, Object?>{
        'hitToken': hit['hitToken'],
        'sceneRevision': 2,
        'viewportId': 'view',
      };
      final denied = AgentRegistry()..register(provider);
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'place_hit',
          arguments: args,
          expectedRevision: 0,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      denied.dispose();
      final placed = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'place_hit',
        arguments: args,
        expectedRevision: 0,
        idempotencyKey: 'placed',
      );
      expect(placed.status, AgentStatus.ok, reason: placed.message);
      expect(commands.canUndo, isTrue);
      final retry = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'place_hit',
        arguments: args,
        expectedRevision: 0,
        idempotencyKey: 'placed',
      );
      expect(retry.status, AgentStatus.ok);
      expect(transport.calls.where((c) => c.$1 == 'addAnchor'), hasLength(1));
      final fresh = await query();
      transport.current = snapshotMessage(revision: 4);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'place_hit',
          arguments: {
            ...args,
            'hitToken':
                ((fresh.data['hits'] as List).single as Map)['hitToken'],
          },
          expectedRevision: 1,
          idempotencyKey: 'stale',
        )).status,
        AgentStatus.stale,
      );
      registry.dispose();
      provider.dispose();
      await session.dispose();
    },
  );
}
