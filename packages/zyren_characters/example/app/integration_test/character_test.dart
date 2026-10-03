import 'dart:io';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_native/surfaces.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:character_lab/character_lab_scene.dart';
import 'package:character_lab/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('skinned locomotion presents and releases', (tester) async {
    final android = Platform.isAndroid;
    final channel = MethodChannel(
      android ? 'zyren/android-surfaces' : 'zyren/scene-views',
    );
    await channel.invokeMethod<void>('connect', {
      'runtime': NativeSurfaces().runtimeToken,
    });
    Future<Map> diagnostics() async =>
        (await channel.invokeMapMethod('diagnostics'))!;
    final baseline = await diagnostics(),
        physicsBefore = PhysicsWorld.nativeCounts;
    late CharacterLabScene lab;
    await tester.runAsync(() async {
      lab = await CharacterLabScene.load();
    });
    final registry = AgentRegistry(grantedScopes: {'characters.locomotion'});
    final controller = createLabController(lab, registry: registry),
        frames = <FrameStats>[];
    final subscription = controller.frameStats.listen(frames.add);
    var disposed = false;
    Future<void> close() async {
      if (disposed) return;
      disposed = true;
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() async {
        await controller.whenDisposed;
        await subscription.cancel();
        await lab.close();
      });
    }

    addTearDown(close);
    Future<void> until(bool Function() done, String phase) async {
      for (var i = 0; i < 1600; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        expect(tester.takeException(), isNull);
        if (controller.status.value case SceneFailed(:final issue)) {
          fail('$phase: ${issue.message}');
        }
        if (done()) return;
      }
      fail('$phase did not finish, steps=${lab.steps}');
    }

    Future<void> view(Size size) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: CharacterLabView(lab: lab, controller: controller),
        ),
      );
    }

    await view(const Size(900, 640));
    await until(
      () => frames.length > 5 && lab.steps > 10,
      'initial presentation',
    );
    final info = await controller.ready;
    expect(info.backend.toLowerCase(), android ? 'vulkan' : 'metal');
    final wide = frames.last.physicalSize;
    lab.setObstacle(true);
    await until(
      () => lab.arrived && lab.character.currentState == 'idle',
      'arrival around obstacle',
    );
    expect(lab.follower.replans, greaterThanOrEqualTo(2));
    expect(lab.model.nodes[0]!.position, Vec3.zero);
    expect(lab.retargeted.nodes[2]!.position.y, closeTo(-.585, 1e-7));
    expect(lab.motor.grounded, isTrue);
    await tester.tap(find.byKey(const Key('pause')));
    await tester.pump();
    final pausedAt = lab.steps, pausedPosition = lab.actor.position;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(lab.steps, pausedAt);
    expect(lab.actor.position, pausedPosition);
    await view(const Size(390, 700));
    controller.invalidate();
    final count = frames.length;
    await until(
      () =>
          frames.length > count && frames.last.physicalSize.width < wide.width,
      'narrow resize',
    );
    expect(find.text('Resume'), findsOneWidget);
    final viewport = await registry.call(
      providerId: 'zyren.viewport',
      instanceId: 'main',
      tool: 'context',
    );
    expect(viewport.status, AgentStatus.ok);
    expect(viewport.data['frameCorrelation'], 'matches-current-state');
    final projected = controller.camera.projectPoint(
      lab.actor.position + const Vec3(0, .35, 0),
      lab.viewport.aspect,
    );
    final pick = await registry.call(
      providerId: 'zyren.viewport',
      instanceId: 'main',
      tool: 'pick',
      arguments: {
        'x': (projected.x + 1) / 2,
        'y': (1 - projected.y) / 2,
        'coordinateSpace': 'normalized',
        'limit': 8,
      },
    );
    expect(pick.status, AgentStatus.ok);
    expect(
      (pick.data['hits'] as List).any(
        (hit) =>
            (hit as Map)['object']['metadata']?['sourceId'] == 'lab/skin.gltf',
      ),
      isTrue,
    );
    final moved = await registry.call(
      providerId: 'zyren.characters.locomotion',
      instanceId: 'biped',
      tool: 'move_to',
      arguments: {
        'target': [1, 0, 1],
      },
      expectedRevision: lab.revision,
      idempotencyKey: 'native-return',
    );
    expect(moved.status, AgentStatus.ok);
    expect(tester.getSize(find.byType(SceneView)).height, greaterThan(400));
    await tester.tap(find.byKey(const Key('pause')));
    await tester.tap(find.byKey(const Key('return')));
    await until(() => lab.steps > pausedAt + 10, 'resume');
    expect(lab.character.currentState, 'walk');
    expect(frames.map((f) => f.readbackBytes), everyElement(0));
    expect(frames.any((f) => f.uploadedBytes > 0), isTrue);
    final presented = await diagnostics();
    expect(
      presented['presented'] as int,
      greaterThan(baseline['presented'] as int),
    );
    lab.setPaused(true);
    lab.removeCharacter();
    controller.invalidate();
    final removalFrames = frames.length;
    await until(() => frames.length > removalFrames, 'removal');
    expect(lab.body.isAlive, isFalse);
    final narrow = frames.last.physicalSize;
    await close();
    final closed = await diagnostics();
    expect(closed['renderers'], baseline['renderers']);
    expect(closed['sessions'], baseline['sessions']);
    expect(closed[android ? 'surfaces' : 'heldDrawables'], 0);
    expect(PhysicsWorld.nativeCounts, physicsBefore);
    expect(registry.discover()['providers'], isEmpty);
    debugPrint(
      'CHARACTER_QUALIFICATION backend=${info.backend} frames=${frames.length} '
      'wide=${wide.width}x${wide.height} narrow=${narrow.width}x${narrow.height} '
      'steps=${lab.steps} rootMotion=pass collision=pass replan=pass IK=pass retarget=pass readback=0 cleanup=pass',
    );
  });
}
