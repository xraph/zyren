import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import '../../zyren/test/shared_graph_test.dart'
    show SharedBackend, EffectPlugin;
import 'controller_test.dart' show frames, host, readback;
import 'support/fakes.dart' show TestPresenter;

void main() {
  testWidgets(
    'failed effect edits report an issue while the viewport keeps rendering',
    (tester) async {
      final backend = SharedBackend(), plugin = EffectPlugin('color');
      final controller = SceneController(
        options: readback,
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          presenterFactory: () => TestPresenter('frame', []),
        ),
      )..use(plugin);
      final issues = <SceneIssue>[];
      final subscription = controller.issues.listen(issues.add);
      addTearDown(subscription.cancel);
      try {
        await tester.pumpWidget(host(SceneView(controller: controller)));
        await frames(tester);
        final first = backend.last!.graph!;
        plugin.failBuild = true;
        plugin.registration.invalidate();
        await frames(tester);
        expect(issues, hasLength(1));
        expect(issues.single.pluginId, 'color');
        expect(controller.status.value, isA<SceneReady>());
        expect(backend.last!.graph, same(first));
        expect(backend.closed, isFalse);
        plugin.failBuild = false;
        plugin.registration.invalidate();
        await frames(tester);
        expect(first.isClosed, isTrue);
        expect(controller.status.value, isA<SceneReady>());
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await frames(tester);
        await controller.whenDisposed;
      }
    },
  );
}
