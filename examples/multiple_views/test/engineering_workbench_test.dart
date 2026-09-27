import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d_engineering/gpu3d_engineering.dart';
import 'package:multiple_views/scene_workbench.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

class ReviewStore implements EngineeringStore {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String document) async {
    if (fail) throw StateError('Disk unavailable');
    value = document;
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> close(WidgetTester tester, SceneController controller) async {
  await tester.pumpWidget(const SizedBox());
  var closed = false;
  controller.whenDisposed.then((_) => closed = true);
  for (var i = 0; i < 30 && !closed; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(closed, isTrue);
}

Future<SceneController> open(
  WidgetTester tester,
  ReviewStore store, {
  FakeBackend? firstBackend,
}) async {
  var backend = firstBackend ?? FakeBackend();
  await tester.pumpWidget(
    SceneWorkbenchApp(
      reviewStore: store,
      runtime: SceneRuntime(
        backendFactory: () async {
          final next = backend;
          backend = FakeBackend();
          return next;
        },
        presenterFactory: () => TestPresenter('frame', backend.events),
      ),
      presentation: PresentationPolicy.readbackOnly,
    ),
  );
  await frames(tester);
  return tester.widget<SceneView>(find.byType(SceneView)).controller!;
}

void main() {
  testWidgets(
    'review edits, native pins, isolation and persistence survive a new scene',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      final store = ReviewStore();
      final backend = FakeBackend();
      var controller = await open(tester, store, firstBackend: backend);
      final parts = controller.scene.children.single.children;
      final housing = parts.first;
      final cover = parts.firstWhere((object) => object.name == 'Cover');
      await tester.tap(find.byKey(const ValueKey('review-tab')));
      await frames(tester);
      await tester.tap(find.byTooltip('Edit metadata'));
      await frames(tester);
      await tester.enterText(
        find.byKey(const ValueKey('metadata-tag')),
        'P-204',
      );
      await tester.tap(find.text('Apply'));
      await frames(tester);
      expect(find.text('tag: P-204'), findsOneWidget);
      await tester.tap(find.byTooltip('Isolate selected'));
      await frames(tester);
      expect(cover.visible, isFalse);
      expect(housing.visible, isTrue);
      await tester.tap(find.byTooltip('Restore visibility'));
      await frames(tester);
      expect(cover.visible, isTrue);
      await tester.tap(find.byTooltip('Add surface note'));
      await frames(tester);
      await tester.tapAt(tester.getCenter(find.byType(SceneView)));
      await frames(tester);
      expect(find.text('Review note'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('annotation-text')),
        'Inspect the seal face',
      );
      await tester.tap(find.text('Apply'));
      await frames(tester);
      final pin = housing.children.singleWhere(
        (object) => object.name == 'Review pin',
      );
      expect(pin, isA<Mesh>());
      final anchor = pin.position;
      expect(find.text('Inspect the seal face'), findsOneWidget);
      backend.renderError = StateError('Device lost');
      controller.invalidate();
      await frames(tester);
      expect(controller.status.value, isA<SceneFailed>());
      var retried = false;
      controller.retry().then((_) => retried = true);
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await frames(tester);
        if (retried && controller.status.value is SceneReady) break;
      }
      expect(controller.status.value, isA<SceneReady>());
      expect(find.text('Inspect the seal face'), findsOneWidget);
      expect(
        housing.children
            .singleWhere((node) => node.name == 'Review pin')
            .position,
        anchor,
      );
      store.fail = true;
      await tester.tap(find.byTooltip('Save review'));
      await frames(tester);
      expect(find.textContaining('Could not save review:'), findsOneWidget);
      expect(find.text('Unsaved'), findsOneWidget);
      store.fail = false;
      await tester.tap(find.byTooltip('Save review'));
      await frames(tester);
      expect(find.text('Saved'), findsOneWidget);
      expect(EngineeringDocument.decode(store.value!).annotations.length, 1);
      await close(tester, controller);
      controller = await open(tester, store);
      final freshHousing = controller.scene.children.single.children.first;
      expect(freshHousing, isNot(same(housing)));
      expect(
        freshHousing.children
            .singleWhere((object) => object.name == 'Review pin')
            .position,
        anchor,
      );
      await tester.tap(find.byKey(const ValueKey('review-tab')));
      await frames(tester);
      expect(find.text('tag: P-204'), findsOneWidget);
      expect(find.text('Inspect the seal face'), findsOneWidget);
      for (final width in [390.0, 320.0]) {
        await tester.binding.setSurfaceSize(Size(width, 700));
        await frames(tester);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SceneView)).height, greaterThan(220));
      }
      await close(tester, controller);
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'malformed reload preserves notes and unsaved reload can be cancelled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      final store = ReviewStore();
      final controller = await open(tester, store);
      await tester.tap(find.byKey(const ValueKey('review-tab')));
      await frames(tester);
      await tester.tap(find.byTooltip('Edit metadata'));
      await frames(tester);
      await tester.enterText(
        find.byKey(const ValueKey('metadata-label')),
        'Edited housing',
      );
      await tester.tap(find.text('Apply'));
      await frames(tester);
      await tester.tap(find.byTooltip('Reload review'));
      await frames(tester);
      expect(find.text('Reload saved review?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await frames(tester);
      expect(find.text('Edited housing'), findsOneWidget);
      store.value = '{bad json';
      await tester.tap(find.byTooltip('Reload review'));
      await frames(tester);
      await tester.tap(find.text('Reload'));
      await frames(tester);
      expect(find.textContaining('Could not load review:'), findsOneWidget);
      expect(find.text('Edited housing'), findsOneWidget);
      expect(find.text('Unsaved'), findsOneWidget);
      await close(tester, controller);
      await tester.binding.setSurfaceSize(null);
    },
  );
}
