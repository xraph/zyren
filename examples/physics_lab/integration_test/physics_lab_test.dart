import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:physics_lab/main.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native physics, controls, reset, resize and disposal', (
    tester,
  ) async {
    final baseline = PhysicsWorld.nativeCounts;
    await tester.pumpWidget(const PhysicsLabApp());
    final state = tester.state<PhysicsLabState>(find.byType(PhysicsLab));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await state.controller.whenDisposed;
    });
    for (
      var i = 0;
      i < 600 && state.controller.status.value is! SceneReady;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
      if (state.controller.status.value case SceneFailed(:final issue)) {
        fail(issue.message);
      }
    }
    expect(state.controller.status.value, isA<SceneReady>());
    final ready = state.controller.status.value as SceneReady;
    if (Platform.isMacOS || Platform.isIOS) {
      expect(ready.info.backend.toLowerCase(), contains('metal'));
    } else if (Platform.isAndroid) {
      expect(ready.info.backend.toLowerCase(), contains('vulkan'));
    }
    debugPrint(
      'Physics Lab renderer: ${ready.info.backend}; '
      'presentation: ${ready.info.presentationPath.name}',
    );
    final initial = state.world.states
        .firstWhere((s) => s.kind == BodyKind.dynamic)
        .pose
        .position
        .y;
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      state.world.states
          .firstWhere((s) => s.kind == BodyKind.dynamic)
          .pose
          .position
          .y,
      lessThan(initial),
    );
    await tester.tap(find.text('Drop ball'));
    await tester.pump();
    expect(state.spawned.length, 1);
    await tester.tap(find.text('Ray cast'));
    await tester.pump();
    expect(state.query, contains('Ray hit collider'));
    await tester.tap(find.text('Overlap'));
    await tester.pump();
    expect(state.query, contains('Overlap found'));
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(state.physics.paused, isTrue);
    final paused = state.world.states
        .firstWhere((s) => s.kind == BodyKind.dynamic)
        .pose
        .position;
    await tester.pump(const Duration(seconds: 1));
    expect(
      state.world.states
          .firstWhere((s) => s.kind == BodyKind.dynamic)
          .pose
          .position,
      paused,
    );
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(state.spawned, isEmpty);
    expect(state.query, 'Snapshot restored.');
    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(state.physics.paused, isFalse);
    state.mover.setTarget(PhysicsPose(position: const Vec3(2, .4, 2)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(state.mover.state.pose.position.x, closeTo(2, .01));
    tester.view.physicalSize = const Size(396, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Debug'));
    await tester.pump();
    expect(state.physics.debug, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await state.controller.whenDisposed;
    expect(PhysicsWorld.nativeCounts, baseline);
  });
}
