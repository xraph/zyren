import 'package:flutter/widgets.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/backend_fake.dart';
import 'support/fakes.dart';

void main() {
  testWidgets(
    'demand frames publish the last sampled stats without rendering again',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        options: const EngineOptions(
          presentation: PresentationPolicy.readbackOnly,
        ),
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          presenterFactory: () => TestPresenter('frame', backend.events),
        ),
      );
      final frames = <FrameStats>[];
      var streamClosed = false;
      controller.frameStats.listen(
        frames.add,
        onDone: () => streamClosed = true,
      );
      Future<void> settleFrame() async {
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SceneView(controller: controller),
        ),
      );
      await settleFrame();
      expect(frames.map((s) => s.drawCalls), [0]);
      controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      await settleFrame();
      controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      await settleFrame();
      final renders = backend.submissions.length;
      expect(backend.submissions.last.scene.drawCalls, 2);
      expect(frames.map((s) => s.drawCalls), [0]);
      await tester.pump(const Duration(milliseconds: 110));
      expect(frames.map((s) => s.drawCalls), [0, 2]);
      expect(backend.submissions.length, renders);

      controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      await settleFrame();
      expect(frames.map((s) => s.drawCalls), [0, 2]);
      controller.dispose();
      await settleFrame();
      await controller.whenDisposed;
      await tester.pump(const Duration(milliseconds: 250));
      expect(frames.map((s) => s.drawCalls), [0, 2]);
      expect(tester.takeException(), isNull);
      expect(streamClosed, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
