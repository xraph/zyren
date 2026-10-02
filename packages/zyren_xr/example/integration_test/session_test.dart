import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_xr/agents.dart';
import 'package:zyren_xr/flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('physical ARKit session, registered placement and release', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text(
            'XR device probe: allow camera access and move the device slowly.',
          ),
        ),
      ),
    );
    final dpr = tester.view.devicePixelRatio;
    final logicalSize = tester.view.physicalSize / dpr;
    await tester.runAsync(() async {
      const transport = MethodChannelXrTransport();
      final capabilities = await XrSession.capabilities(transport);
      expect(
        capabilities.worldTracking,
        isTrue,
        reason: 'A physical ARKit device is required.',
      );
      expect(capabilities.cameraPresentation, isFalse);
      expect(capabilities.depthOcclusion, isFalse);
      final session = await XrSession.create(transport);
      final registry = AgentRegistry(grantedScopes: {'xr.place'});
      XrAgentProvider? provider;
      try {
        await session.start().timeout(const Duration(seconds: 30));
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        XrSnapshot snapshot;
        do {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          snapshot = await session.snapshot();
        } while (snapshot.frame?.tracking != XrTrackingState.normal &&
            DateTime.now().isBefore(deadline));
        expect(snapshot.frame?.tracking, XrTrackingState.normal);
        provider = XrAgentProvider(
          instanceId: 'device-probe',
          commands: XrPlacementCommands(session),
          deviceCapabilities: capabilities,
          view: () => XrViewBinding(
            sceneId: 'probe-scene',
            documentId: 'unsaved',
            viewportId: 'probe',
            cameraId: 'sensor',
            sceneRevision: 0,
            logicalRect: [0, 0, logicalSize.width, logicalSize.height],
            devicePixelRatio: dpr,
            sceneFromSession: XrPose.identity(),
          ),
          allowPlacement: true,
        );
        final registration = registry.register(provider);
        expect(
          await AgentConformance.checkRead(
            registry: registry,
            provider: provider,
            tool: 'inspect',
          ),
          isEmpty,
        );
        snapshot = await session.snapshot();
        final result = await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'place_anchor',
          expectedRevision: 0,
          idempotencyKey: 'place-1',
          arguments: {
            'transform': snapshot.frame!.cameraPose.matrix,
            'sessionRevision': snapshot.revision,
            'frameTimestamp': snapshot.frame!.timestamp,
            'sceneRevision': 0,
            'viewportId': 'probe',
          },
        );
        expect(result.status, AgentStatus.ok, reason: result.message);
        expect(result.affectedIds.single, isNotEmpty);
        final undo = await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'undo_placement',
          expectedRevision: 1,
          idempotencyKey: 'undo-1',
          arguments: {'sceneRevision': 0, 'viewportId': 'probe'},
        );
        expect(undo.status, AgentStatus.ok, reason: undo.message);
        await session.pause();
        final paused = await session.snapshot();
        expect(paused.state, XrSessionState.paused);
        expect(paused.frame, isNull);
        registration.dispose();
        expect(registry.discover()['providers'], isEmpty);
      } finally {
        registry.dispose();
        provider?.dispose();
        await session.dispose();
      }
      await expectLater(session.snapshot(), throwsA(isA<XrException>()));
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
