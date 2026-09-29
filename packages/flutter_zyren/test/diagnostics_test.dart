import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'controller_test.dart' show frames, host, readback, runtime;
import 'support/backend_fake.dart';

void main() {
  testWidgets(
    'last presented stats are available while idle and clear on failure',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      expect(controller.latestFrameStats, isNull);
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      final stats = controller.latestFrameStats!;
      expect(stats.frameId, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.latestFrameStats, same(stats));
      expect(backend.submissions.length, 1);
      backend.renderError = StateError('test device failure');
      controller.invalidate();
      await frames(tester);
      expect(controller.status.value, isA<SceneFailed>());
      expect(controller.latestFrameStats, isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await controller.whenDisposed;
    },
  );
}
