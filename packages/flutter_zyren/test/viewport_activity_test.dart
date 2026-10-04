import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/src/input/flutter_input_adapter.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show host, frames, readback, runtime;

void main() {
  test('reentrant close still revokes later listeners exactly once', () {
    for (final closeDirectly in [true, false]) {
      final source = FlutterInputAdapter();
      final events = <bool>[];
      source.listenViewportActivity((active) {
        if (!active) source.close();
      });
      source.listenViewportActivity(events.add);
      if (closeDirectly) {
        source.close();
      } else {
        source.setActive(false);
      }
      expect(events, [false]);
      expect(source.viewportActive, isFalse);
      source.close();
      expect(() => source.listenViewportActivity(events.add), throwsStateError);
    }
  });
  testWidgets('throwing listener cannot block suspension or close', (
    tester,
  ) async {
    final source = FlutterInputAdapter();
    final failure = StateError('activity listener');
    final events = <bool>[];
    source.listenViewportActivity((_) => throw failure);
    source.listenViewportActivity(events.add);
    source.setActive(false);
    expect(events, [false]);
    await tester.pump();
    expect(tester.takeException(), same(failure));
    source.setActive(true);
    await tester.pump();
    expect(tester.takeException(), same(failure));
    source.close();
    expect(events, [false, true, false]);
    expect(source.viewportActive, isFalse);
    await tester.pump();
    expect(tester.takeException(), same(failure));
  });

  testWidgets(
    'failure and retry keep activity revoked until old backend retires',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        runtime: runtime(backend),
        options: readback,
      );
      final activity = controller.input as ViewportActivitySource;
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      expect(activity.viewportActive, isTrue);
      final listenerFailure = StateError('suspend listener failed');
      final broken = activity.listenViewportActivity((active) {
        if (!active) throw listenerFailure;
      });
      final events = <bool>[];
      final following = activity.listenViewportActivity(events.add);
      final original = StateError('renderer failed');
      backend.closeGate = Completer<void>();
      backend.renderError = original;
      controller.invalidate();
      await frames(tester);
      expect(tester.takeException(), same(listenerFailure));
      expect(controller.status.value, isA<SceneFailed>());
      expect(
        (controller.status.value as SceneFailed).issue.cause,
        same(original),
      );
      expect(activity.viewportActive, isFalse);
      expect(events, [false]);
      backend.renderError = null;
      final recovered = controller.retry();
      await frames(tester);
      expect(controller.status.value, isA<SceneRecovering>());
      expect(activity.viewportActive, isFalse);
      expect(events, [false]);
      backend.closeGate!.complete();
      await frames(tester);
      await recovered;
      await frames(tester);
      expect(controller.status.value, isA<SceneReady>());
      expect(activity.viewportActive, isTrue);
      expect(events, [false, true]);
      broken.dispose();
      following.dispose();
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
    },
  );
  test('viewport activity changes synchronously and close revokes it', () {
    final source = FlutterInputAdapter();
    final events = <bool>[];
    final listener = source.listenViewportActivity(events.add);
    source.setActive(false);
    expect(events, [false]);
    source.setActive(false);
    source.setActive(true);
    source.close();
    expect(events, [false, true, false]);
    expect(source.viewportActive, isFalse);
    expect(() => source.listenViewportActivity(events.add), throwsStateError);
    listener.dispose();
  });

  testWidgets('TickerMode and unmount revoke host activity without focus', (
    tester,
  ) async {
    final controller = SceneController(
      runtime: runtime(FakeBackend()),
      options: readback,
    );
    final activity = controller.input as ViewportActivitySource;
    final events = <bool>[];
    final listener = activity.listenViewportActivity(events.add);
    Widget view(bool enabled) => host(
      TickerMode(
        enabled: enabled,
        child: SceneView(controller: controller),
      ),
    );
    await tester.pumpWidget(view(true));
    await frames(tester);
    expect(activity.viewportActive, isTrue);
    await tester.pumpWidget(view(false));
    await frames(tester);
    expect(activity.viewportActive, isFalse);
    await tester.pumpWidget(view(true));
    await frames(tester);
    expect(activity.viewportActive, isTrue);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    expect(activity.viewportActive, isFalse);
    expect(events, containsAllInOrder([false, true, false]));
    listener.dispose();
    controller.dispose();
    await controller.whenDisposed;
  });
}
