import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'support/backend_fake.dart';
import 'support/fakes.dart';
import 'controller_test.dart' show frames, host, runtime, readback;

void main() {
  testWidgets(
    'automatic device recovery makes one attempt and then fails visibly',
    (tester) async {
      var creates = 0;
      final backends = <FakeBackend>[];
      final controller = SceneController(
        options: const EngineOptions(
          presentation: PresentationPolicy.readbackOnly,
          recovery: RecoveryPolicy.automaticOnce,
        ),
        runtime: SceneRuntime(
          backendFactory: () async {
            creates++;
            final backend = FakeBackend()
              ..renderError = SceneException(
                SceneIssue(
                  code: SceneIssueCodes.deviceLost,
                  message: 'test device loss',
                  operation: 'render',
                ),
              );
            backends.add(backend);
            return backend;
          },
          presenterFactory: () => TestPresenter('frame', []),
        ),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      await frames(tester);
      expect(creates, 2);
      expect(
        (controller.status.value as SceneFailed).issue.code,
        SceneIssueCodes.deviceLost,
      );
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      expect(backends.map((b) => b.closeCount), everyElement(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'frame diagnostics are sampled without lifecycle notifications each frame',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      var changes = 0;
      final statistics = <FrameStats>[];
      controller.status.addListener(() => changes++);
      final subscription = controller.frameStats.listen(statistics.add);
      addTearDown(subscription.cancel);
      final demand = controller.onUpdate((_) {});
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      final before = changes;
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(backend.submissions.length, greaterThan(20));
      expect(changes, before);
      expect(statistics.length, lessThanOrEqualTo(7));
      demand.dispose();
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('default shared policy fails visibly and closes its backend', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = SceneController(runtime: runtime(backend));
    final ready = expectLater(
      controller.ready,
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          'presentationUnavailable',
        ),
      ),
    );
    await tester.pumpWidget(host(SceneView(controller: controller)));
    await frames(tester);
    await ready;
    expect(controller.status.value, isA<SceneFailed>());
    expect(backend.closeCount, 1);
    expect(backend.submissions, isEmpty);
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    await tester.pumpWidget(const SizedBox());
  });
  for (final policy in [
    PresentationPolicy.allowReadback,
    PresentationPolicy.readbackOnly,
  ]) {
    testWidgets('$policy reports readback explicitly', (tester) async {
      final backend = FakeBackend()
        ..additionalFeatures = {RenderFeature.sharedTexture};
      final controller = SceneController(
        options: EngineOptions(presentation: policy),
        runtime: runtime(backend),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      expect(
        (await controller.ready).presentationPath,
        PresentationPath.readback,
      );
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('unsupported plugin reports its ID and requirement', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = SceneController(
      options: readback,
      runtime: runtime(backend),
    );
    controller.use(
      TestPlugin('compute-demo', [], requiredFeatures: {RenderFeature.compute}),
    );
    await tester.pumpWidget(host(SceneView(controller: controller)));
    await frames(tester);
    final issue = (controller.status.value as SceneFailed).issue;
    expect(issue.code, SceneIssueCodes.unsupportedFeature);
    expect(issue.pluginId, 'compute-demo');
    expect(issue.requiredFeatures, {RenderFeature.compute});
    expect(backend.closeCount, 1);
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    await tester.pumpWidget(const SizedBox());
  });
  test('invalid FPS fails synchronously before a backend is allocated', () {
    expect(
      () =>
          SceneController(options: const EngineOptions(maxFramesPerSecond: 0)),
      throwsArgumentError,
    );
  });
}
