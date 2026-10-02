import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_capture/zyren_capture.dart';
import 'package:zyren_capture/agents.dart';
import 'package:zyren_capture/effects_agents.dart';
import 'capture_test.dart' show FixtureBackend;

void main() {
  test(
    'capture discovery, schemas, start/retry, artifacts and detach cancellation',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'zyren-capture-agents-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final manager = CaptureManager(
        scene: Scene(),
        sceneId: 'scene',
        documentId: 'doc',
        outputParent: dir,
        openBackend: () async => FixtureBackend(),
      );
      addTearDown(manager.close);
      final provider = CaptureAgentProvider(
        manager: manager,
        instanceId: 'capture',
        maxDimension: 64,
        maxFrames: 4,
      );
      final registry = AgentRegistry(grantedScopes: {'capture.write'}),
          registration = provider.register(registry);
      addTearDown(registry.dispose);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'jobs',
        ),
        isEmpty,
      );
      final rev = provider.revision;
      Future<AgentResult> start() => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'start',
        arguments: {'jobId': 'one', 'width': 2, 'height': 2},
        expectedRevision: rev,
        idempotencyKey: 'one',
      );
      final result = await start();
      expect(result.status, AgentStatus.ok);
      expect(await start(), same(result));
      await manager.jobs.single.done;
      final state = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'jobs',
      );
      expect((state.data['jobs'] as List).single['state'], 'completed');
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'start',
          arguments: {'jobId': 'large', 'width': 65, 'height': 2},
          expectedRevision: provider.revision,
          idempotencyKey: 'large',
        )).status,
        AgentStatus.invalid,
      );
      final denied = AgentRegistry()..register(provider);
      addTearDown(denied.dispose);
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'cancel',
          arguments: {'jobId': 'one'},
          expectedRevision: provider.revision,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      final next = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'start',
        arguments: {'jobId': 'two', 'width': 2, 'height': 2, 'frames': 4},
        expectedRevision: provider.revision,
        idempotencyKey: 'two',
      );
      expect(next.status, AgentStatus.ok);
      registration.dispose();
      await expectLater(
        manager.jobs.last.done,
        throwsA(isA<CaptureCancelled>()),
      );
      expect(registry.discover()['providers'], isEmpty);
      expect(await dir.list().length, 1);
    },
  );

  test(
    'effects adapter inspects, controls and undoes actual scene settings',
    () async {
      final scene = Scene();
      final provider = EffectsAgentProvider(
        scene: scene,
        sceneId: 'scene',
        documentId: 'doc',
        instanceId: 'effects',
      );
      final registry = AgentRegistry(grantedScopes: {'effects.write'}),
          registration = registry.register(provider);
      addTearDown(registry.dispose);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'inspect',
        ),
        isEmpty,
      );
      final changed = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'configure',
        arguments: {'exposure': 2.0, 'hdr': true},
        expectedRevision: provider.revision,
        idempotencyKey: 'change',
      );
      expect(changed.status, AgentStatus.ok);
      expect(scene.renderSettings.exposure, 2);
      expect(scene.renderSettings.hdr, isTrue);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'undo',
          expectedRevision: provider.revision,
          idempotencyKey: 'undo',
        )).status,
        AgentStatus.ok,
      );
      expect(scene.renderSettings.exposure, 1);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'configure',
          arguments: {'exposure': -1},
          expectedRevision: provider.revision,
          idempotencyKey: 'bad',
        )).status,
        AgentStatus.invalid,
      );
      scene.add(Group());
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'undo',
          expectedRevision: provider.revision,
          idempotencyKey: 'stale',
        )).status,
        AgentStatus.stale,
      );
      registration.dispose();
      expect(registry.discover()['providers'], isEmpty);
    },
  );
}
