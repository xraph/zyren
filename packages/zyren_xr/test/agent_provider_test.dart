import 'dart:async';

import 'package:test/test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_xr/agents.dart';
import 'package:zyren_xr/zyren_xr.dart';

import 'fixtures.dart';

XrViewBinding binding({int revision = 4, String viewport = 'xr-view'}) =>
    XrViewBinding(
      sceneId: 'scene-1',
      documentId: 'doc-1',
      viewportId: viewport,
      cameraId: 'camera-1',
      sceneRevision: revision,
      logicalRect: [0, 0, 400, 600],
      devicePixelRatio: 3,
      sceneFromSession: XrPose.identity(),
    );

void main() {
  late RecordingTransport transport;
  late XrSession session;
  late XrPlacementCommands commands;
  late XrAgentProvider provider;
  late AgentRegistry registry;
  late XrViewBinding currentView;
  setUp(() async {
    transport = RecordingTransport();
    session = await XrSession.create(transport);
    commands = XrPlacementCommands(session);
    currentView = binding();
    provider = XrAgentProvider(
      instanceId: 'xr-1',
      commands: commands,
      deviceCapabilities: XrCapabilities.fromMessage(capabilitiesMessage()),
      view: () => currentView,
      allowPlacement: true,
    );
    registry = AgentRegistry(grantedScopes: {'xr.place'});
    registry.register(provider);
  });
  tearDown(() async {
    registry.dispose();
    provider.dispose();
    await session.dispose();
  });

  Future<AgentResult> place({
    int revision = 0,
    String key = 'placement-1',
    AgentCancellation? cancellation,
  }) => registry.call(
    providerId: provider.id,
    instanceId: provider.instanceId,
    tool: 'place_anchor',
    expectedRevision: revision,
    idempotencyKey: key,
    cancellation: cancellation,
    arguments: {
      'transform': XrPose.identity().matrix,
      'sessionRevision': 1,
      'frameTimestamp': 12.0,
      'sceneRevision': 4,
      'viewportId': 'xr-view',
    },
  );

  test(
    'shared discovery and conformance report live domain queries and unknown pixels',
    () async {
      final discovery = registry.discover();
      final described = (discovery['providers'] as List).single as Map;
      expect(described['providerId'], 'zyren.xr');
      expect((described['tools'] as List).length, 3);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'inspect',
        ),
        isEmpty,
      );
      final result = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'inspect',
        arguments: {'limit': 2},
      );
      expect(result.status, AgentStatus.ok);
      expect((result.data['view'] as Map)['devicePixelRatio'], 3);
      expect((result.data['view'] as Map)['presentedFrameId'], isNull);
      expect((result.data['view'] as Map)['renderedPixelEvidence'], 'unknown');
      expect(result.data['availableActions'], ['place_anchor']);
      expect(transport.calls.where((c) => c.$1 == 'addAnchor'), isEmpty);
    },
  );

  test(
    'permission, valid placement, retry and undo use ordinary commands',
    () async {
      final deniedRegistry = AgentRegistry()..register(provider);
      final denied = await deniedRegistry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'undo_placement',
        arguments: {'sceneRevision': 4, 'viewportId': 'xr-view'},
        expectedRevision: 0,
        idempotencyKey: 'denied',
      );
      expect(denied.status, AgentStatus.denied);
      deniedRegistry.dispose();
      final placed = await place();
      expect(placed.status, AgentStatus.ok, reason: placed.message);
      expect(placed.affectedIds, ['anchor-1']);
      expect(placed.revision, 1);
      final retry = await place();
      expect(retry.status, AgentStatus.ok);
      expect(transport.calls.where((c) => c.$1 == 'addAnchor').length, 1);
      transport.current = snapshotMessage(revision: 2);
      final undone = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'undo_placement',
        arguments: {'sceneRevision': 4, 'viewportId': 'xr-view'},
        expectedRevision: 1,
        idempotencyKey: 'undo-1',
      );
      expect(undone.status, AgentStatus.ok, reason: undone.message);
      expect(commands.canUndo, isFalse);
      expect(undone.revision, 2);
      expect(transport.calls.last.$2['expectedRevision'], 2);
    },
  );

  test(
    'stale native origin, frame age, view and tracking refuse placement',
    () async {
      transport.current = snapshotMessage(revision: 7);
      expect((await place()).status, AgentStatus.stale);
      transport.current = snapshotMessage()..['nativeTimestamp'] = 15.0;
      expect((await place(key: 'old-frame')).status, AgentStatus.stale);
      transport.current = snapshotMessage(tracking: 'limited');
      expect((await place(key: 'limited')).status, AgentStatus.unavailable);
      transport.current = snapshotMessage();
      currentView = binding(viewport: 'different-view');
      expect((await place(key: 'other-view')).status, AgentStatus.stale);
      expect(transport.calls.where((c) => c.$1 == 'addAnchor'), isEmpty);
    },
  );

  test(
    'scene changes while awaiting native snapshot refuse mutation',
    () async {
      transport.handler = (method, _) {
        if (method == 'snapshot') {
          currentView = binding(revision: 5);
          return snapshotMessage();
        }
        return null;
      };
      expect((await place()).status, AgentStatus.stale);
      expect(transport.calls.where((c) => c.$1 == 'addAnchor'), isEmpty);
    },
  );

  test(
    'cancellation and unregister during query release the registry',
    () async {
      final pending = Completer<Object?>();
      transport.handler = (method, _) =>
          method == 'snapshot' ? pending.future : null;
      final token = AgentCancellation();
      final placing = place(cancellation: token);
      token.cancel();
      pending.complete(snapshotMessage());
      expect((await placing).status, AgentStatus.cancelled);
      expect(transport.calls.where((c) => c.$1 == 'addAnchor'), isEmpty);
      registry.dispose();
      final unavailable = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'inspect',
      );
      expect(unavailable.status, AgentStatus.unavailable);
    },
  );

  test(
    'input schema bounds output pages and disallows arbitrary commands',
    () async {
      final invalid = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'inspect',
        arguments: {'limit': 9999},
      );
      expect(invalid.status, AgentStatus.invalid);
      final unknown = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'eval',
        arguments: {},
      );
      expect(unknown.status, AgentStatus.unsupported);
    },
  );
}
