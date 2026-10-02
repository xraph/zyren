import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'support/backend_fake.dart';
import 'support/fakes.dart';

Widget host(SceneController controller, {bool visible = true}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: TickerMode(
        enabled: visible,
        child: Center(
          child: SizedBox(
            width: 64,
            height: 64,
            child: SceneView(controller: controller),
          ),
        ),
      ),
    );
Future<void> frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets(
    'presentation samples follow presenter completion without throttling',
    (tester) async {
      final backend = FakeBackend();
      final gate = Completer<void>();
      final presenter = TestPresenter('sample', backend.events, gate: gate);
      final controller = SceneController(
        options: const EngineOptions(
          presentation: PresentationPolicy.readbackOnly,
        ),
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          presenterFactory: () => presenter,
        ),
      );
      controller.onUpdate((_) {});
      final samples = <PresentationSample>[];
      final diagnostics = <FrameStats>[];
      var closed = false;
      final subscription = controller.presentations.listen(
        samples.add,
        onDone: () => closed = true,
      );
      var diagnosticsClosed = false;
      controller.frameStats.listen(
        diagnostics.add,
        onDone: () => diagnosticsClosed = true,
      );
      await tester.pumpWidget(host(controller));
      await frames(tester);
      expect(backend.submissions, isNotEmpty);
      expect(samples, isEmpty, reason: 'rendering alone is not presentation');
      gate.complete();
      await frames(tester);
      expect(samples.length, greaterThan(3));
      expect(samples.length, greaterThan(diagnostics.length));
      expect(samples.first.interval, isNull);
      for (var i = 1; i < samples.length; i++) {
        expect(
          samples[i].frame.frameId,
          greaterThan(samples[i - 1].frame.frameId),
        );
        expect(
          samples[i].elapsed,
          greaterThanOrEqualTo(samples[i - 1].elapsed),
        );
        expect(
          samples[i].interval,
          samples[i].elapsed - samples[i - 1].elapsed,
        );
      }
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      await controller.whenDisposed;
      expect(closed, isTrue);
      unawaited(subscription.cancel());
      expect(diagnosticsClosed, isTrue);
      await tester.pump();
    },
  );

  testWidgets('new subscriptions and remounts start a fresh pacing interval', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = SceneController(
      options: const EngineOptions(
        presentation: PresentationPolicy.readbackOnly,
      ),
      runtime: SceneRuntime(
        backendFactory: () async => backend,
        presenterFactory: () => TestPresenter('sample', backend.events),
      ),
    );
    controller.onUpdate((_) {});
    final samples = <PresentationSample>[];
    var subscription = controller.presentations.listen(samples.add);
    await tester.pumpWidget(host(controller));
    await frames(tester);
    unawaited(subscription.cancel());
    samples.clear();
    await frames(tester);
    subscription = controller.presentations.listen(samples.add);
    await frames(tester);
    expect(samples.first.interval, isNull);
    await tester.pumpWidget(host(controller, visible: false));
    await frames(tester);
    final paused = samples.length;
    await frames(tester);
    expect(samples.length, paused);
    samples.clear();
    await tester.pumpWidget(host(controller));
    await frames(tester);
    expect(samples.first.interval, isNull);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    samples.clear();
    await tester.pumpWidget(host(controller));
    await frames(tester);
    expect(samples.first.interval, isNull);
    controller.dispose();
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await controller.whenDisposed;
    unawaited(subscription.cancel());
    await tester.pump();
  });
}
