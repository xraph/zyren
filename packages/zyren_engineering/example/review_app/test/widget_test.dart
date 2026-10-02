import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_engineering_review/main.dart';
import 'package:zyren_engineering_review/review_workspace.dart';
import '../../../../flutter_zyren/test/support/backend_fake.dart';
import '../../../../flutter_zyren/test/support/fakes.dart' show TestPresenter;

class MemorySession implements EngineeringSessionStore {
  EngineeringRevision revision;
  bool denied = false;
  int writes = 0;
  MemorySession(this.revision);
  @override
  Future<EngineeringRevision> read() async => revision;
  @override
  Future<EngineeringRevision> compareAndWrite({
    required String expectedVersion,
    required EngineeringDocument document,
  }) async {
    if (denied) throw StateError('HTTP 403: read-only access');
    if (expectedVersion != revision.version)
      throw const EngineeringVersionConflict();
    return revision = EngineeringRevision(
      version: '${++writes}',
      document: document,
    );
  }
}

Future<void> waitForWork(WidgetTester tester, ReviewWorkspace work) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (!work.busy) return;
  }
  fail('Review operation did not complete: ${work.message}');
}

void main() {
  for (final width in [1100.0, 390.0]) {
    testWidgets('review import, notes and reload fit width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend()..maxDimension = 4096;
      final work = ReviewWorkspace(
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          presenterFactory: () => TestPresenter('Native test surface', []),
        ),
        presentation: PresentationPolicy.readbackOnly,
      );
      debugPrint('START APP');
      await tester.pumpWidget(ReviewApp(workspace: work));
      await tester.pumpAndSettle();
      debugPrint('START DEMO');
      unawaited(work.demo());
      await waitForWork(tester, work);
      debugPrint('WORK DONE ${work.error}');
      await tester.pumpAndSettle();
      expect(work.error, isNull);
      expect(work.root, isNotNull);
      if (width < 850) {
        await tester.tap(find.text('Review (0)'));
        await tester.pumpAndSettle();
      }
      debugPrint('START NOTE');
      await tester.tap(find.byKey(const Key('add-note')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('note-text')),
        'Inspect flange',
      );
      await tester.tap(find.byKey(const Key('save-note')));
      await tester.pumpAndSettle();
      debugPrint('NOTE DONE');
      expect(find.text('Inspect flange'), findsOneWidget);
      final id = work.review.document.annotations.keys.single;
      unawaited(work.reload());
      await waitForWork(tester, work);
      debugPrint('WORK DONE ${work.error}');
      await tester.pumpAndSettle();
      expect(work.review.worldAnchor(id), isNotNull);
      expect(work.review.document.annotations[id]!.text, 'Inspect flange');
      expect(tester.takeException(), isNull);
      debugPrint('START DISPOSE');
      await tester.pumpWidget(const SizedBox());
      work.dispose();
      await tester.pump();
      await work.controller.whenDisposed;
      debugPrint('DISPOSE DONE');
    });
  }
  testWidgets(
    'denial keeps edits, exact conflicts require a choice, retry writes',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final work = ReviewWorkspace(
        runtime: SceneRuntime(
          backendFactory: () async => FakeBackend()..maxDimension = 4096,
          presenterFactory: () => TestPresenter('Native test surface', []),
        ),
        presentation: PresentationPolicy.readbackOnly,
      );
      debugPrint('START APP');
      await tester.pumpWidget(ReviewApp(workspace: work));
      await tester.pumpAndSettle();
      debugPrint('START DEMO');
      unawaited(work.demo());
      await waitForWork(tester, work);
      debugPrint('WORK DONE ${work.error}');
      await tester.pumpAndSettle();
      work.putNote('Initial');
      final store = MemorySession(
        EngineeringRevision(
          version: 'empty',
          document: EngineeringDocument(id: 'review'),
        ),
      );
      await work.attachSession(store, 'fixture');
      await work.sync();
      await tester.pumpAndSettle();
      final note = work.review.document.annotations.values.single;
      work.putNote('Local edit', existing: note);
      store.denied = true;
      await tester.tap(find.byKey(const Key('sync')));
      await tester.pumpAndSettle();
      expect(work.error, contains('403'));
      expect(work.review.document.annotations[note.id]!.text, 'Local edit');
      store.denied = false;
      await work.retry!();
      await tester.pumpAndSettle();
      expect(store.revision.document.annotations[note.id]!.text, 'Local edit');
      final objects = store.revision.document.objects.values;
      store.revision = EngineeringRevision(
        version: 'remote',
        document: EngineeringDocument(
          id: 'review',
          objects: objects,
          annotations: [
            EngineeringAnnotation(
              id: note.id,
              objectId: note.objectId,
              text: 'Remote edit',
              anchor: note.anchor,
            ),
          ],
        ),
      );
      work.putNote('Local conflict', existing: note);
      await work.sync();
      await tester.pumpAndSettle();
      expect(work.conflicts, hasLength(1));
      final apply = find.byKey(const Key('apply-conflicts'));
      await tester.ensureVisible(apply);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      final dropdown = find.byType(
        DropdownButtonFormField<EngineeringConflictChoice>,
      );
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('remote').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(work.conflicts, isEmpty);
      expect(work.review.document.annotations[note.id]!.text, 'Remote edit');
      expect(tester.takeException(), isNull);
      debugPrint('START DISPOSE');
      await tester.pumpWidget(const SizedBox());
      work.dispose();
      await tester.pump();
      await work.controller.whenDisposed;
      debugPrint('DISPOSE DONE');
    },
  );
}
