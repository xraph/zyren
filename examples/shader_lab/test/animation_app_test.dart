import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_lab/animation.dart';
import 'pbr_app_test.dart' show PbrBackend;
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

void main() {
  testWidgets('independent animation controls fit desktop and narrow screens', (
    tester,
  ) async {
    final backend = PbrBackend();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      AnimationLabApp(
        autoplay: false,
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          presenterFactory: () => TestPresenter('animation', backend.events),
        ),
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    Group arm(String name) => controller.scene.children
        .whereType<Group>()
        .singleWhere((g) => g.name == name)
        .children
        .whereType<Group>()
        .single;
    final right = arm('Right').quaternion, left = arm('Left').quaternion;
    await tester.drag(
      find.byKey(const ValueKey('Playhead')),
      const Offset(35, 0),
    );
    await tester.pumpAndSettle();
    expect(arm('Left').quaternion, isNot(left));
    expect(arm('Right').quaternion, right);
    tester
        .widget<DropdownButton<int>>(find.byKey(const ValueKey('Repetitions')))
        .onChanged!(2);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<int>>(
            find.byKey(const ValueKey('Repetitions')),
          )
          .value,
      2,
    );
    for (final size in [
      const Size(390, 700),
      const Size(1100, 700),
      const Size(320, 640),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(250));
    }
    await tester.tap(find.text('Right'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('Restart')));
    await tester.pumpAndSettle();
    expect(arm('Right').quaternion, left);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => controller.whenDisposed);
    expect(backend.closeCount, 1);
  });
}
