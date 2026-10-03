import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_capture/zyren_capture.dart';
import 'package:zyren_capture/video_agents.dart';
import 'capture_test.dart' show FixtureBackend;

void main() {
  test(
    'video tools enforce scopes, retry admission and cancel on detach',
    () async {
      final dir = await Directory.systemTemp.createTemp('zyren-video-agents-');
      addTearDown(() => dir.delete(recursive: true));
      final captures = CaptureManager(
        scene: Scene(),
        sceneId: 'scene',
        documentId: 'doc',
        outputParent: dir,
        openBackend: () async => FixtureBackend(),
      );
      addTearDown(captures.close);
      await captures
          .start(
            id: 'png',
            plan: CapturePlan(size: PhysicalSize(16, 16)),
          )
          .done;
      final provider = VideoAgentProvider(
        captures: captures,
        outputParent: dir,
        instanceId: 'video',
      );
      final registry = AgentRegistry(grantedScopes: {'capture.video'}),
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
      final denied = AgentRegistry()..register(provider);
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: 'video',
          tool: 'start',
          arguments: {'jobId': 'bad', 'captureId': 'png', 'fps': 30},
          expectedRevision: provider.revision,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      denied.dispose();
      final revision = provider.revision;
      Future<AgentResult> start() => registry.call(
        providerId: provider.id,
        instanceId: 'video',
        tool: 'start',
        arguments: {'jobId': 'one', 'captureId': 'png', 'fps': 30},
        expectedRevision: revision,
        idempotencyKey: 'one',
      );
      final first = await start();
      expect(first.status, AgentStatus.ok);
      expect(await start(), same(first));
      registration.dispose();
      expect(registry.discover()['providers'], isEmpty);
      // No executable is needed: detach occurs before the export's event turn.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await dir.list().length, 1);
    },
  );
}
