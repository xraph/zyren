import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:multiple_views/declarative_demo.dart';
import '../../../packages/flutter_zyren/test/support/backend_fake.dart';
import 'api_examples_test.dart' show frames, runtime;

void main() {
  for (final size in [const Size(1024, 768), const Size(360, 740)]) {
    testWidgets('declarative controls and canvas fit $size', (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(size);
      final backend = FakeBackend()..maxDimension = 2048;
      late SceneController controller;
      await tester.pumpWidget(
        DeclarativeDemo(
          runtime: runtime(backend),
          options: const EngineOptions(
            presentation: PresentationPolicy.readbackOnly,
          ),
          onCreated: (value) => controller = value,
        ),
      );
      await frames(tester);
      expect(controller.status.value, isA<SceneReady>());
      final group = controller.scene.children.single;
      final cube = group.children.first as Mesh;
      final sphere = group.children.last;
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(400));
      await tester.tap(find.text('Pause'));
      await frames(tester);
      final rotation = cube.quaternion;
      await frames(tester);
      expect(cube.quaternion, rotation);
      await tester.tap(find.byType(Slider));
      await frames(tester);
      expect(group.children.first, same(cube));
      await tester.tap(find.text('Remove cube'));
      await frames(tester);
      expect(group.children, [sphere]);
      expect(cube.parent, isNull);
      await tester.tap(find.text('Add cube'));
      await frames(tester);
      expect(group.children, hasLength(2));
      expect(group.children, contains(sphere));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      // Stream cancellation crosses the test's fake and root async zones.
      var disposed = false;
      controller.whenDisposed.then((_) => disposed = true);
      for (var i = 0; i < 30 && !disposed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump();
      }
      expect(disposed, isTrue);
      expect(backend.closeCount, 1);
    });
  }
}
