import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_engineering/file_session_store.dart';
import 'package:zyren_engineering/review_server.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_engineering_review/main.dart';
import 'package:zyren_engineering_review/review_workspace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native CAD review reload, local persistence and shared conflict recovery',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final temp = await Directory.systemTemp.createTemp(
        'zyren-native-review-',
      );
      final store = FileEngineeringSessionStore(
        file: File('${temp.path}/session.json'),
        documentId: 'review',
      );
      await store.initialize(EngineeringDocument(id: 'review'));
      var canWrite = false;
      final server = await EngineeringReviewServer.start(
        store: store,
        authorize: (request, write) async =>
            request.headers.value('authorization') ==
                'Bearer integration-fixture-token' &&
            (!write || canWrite),
      );
      final work = ReviewWorkspace(runtime: const SceneRuntime.nativeMetal());
      final frames = <FrameStats>[];
      final subscription = work.controller.frameStats.listen(frames.add);
      addTearDown(() async {
        await subscription.cancel();
        await server.close();
        await temp.delete(recursive: true);
      });
      await tester.pumpWidget(ReviewApp(workspace: work));
      Future<void> settleWork() async {
        for (var i = 0; i < 1200; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (!work.busy) break;
        }
        expect(work.busy, isFalse);
        await tester.pumpAndSettle();
      }

      await tester.pumpAndSettle();
      await work.controller.ready.timeout(const Duration(seconds: 30));
      unawaited(work.demo());
      await settleWork();
      expect(work.error, isNull);
      expect(work.root, isNotNull);
      await tester.ensureVisible(find.byKey(const Key('add-note')));
      await tester.tap(find.byKey(const Key('add-note')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('note-text')),
        'Inspect seal',
      );
      await tester.tap(find.byKey(const Key('save-note')));
      await tester.pumpAndSettle();
      final note = work.review.document.annotations.values.single;
      final before = work.review.worldAnchor(note.id);
      unawaited(work.reload());
      await settleWork();
      expect(work.review.worldAnchor(note.id), before);
      const python = String.fromEnvironment('ZYREN_CAD_PYTHON');
      if (python.isNotEmpty) {
        unawaited(
          work.convert(
            python: python,
            script: const String.fromEnvironment('ZYREN_CAD_CONVERTER'),
            source: const String.fromEnvironment('ZYREN_CAD_FIXTURE'),
            destination: '${temp.path}/converted',
          ),
        );
        await settleWork();
        expect(work.error, isNull);
        expect(
          work.review.worldAnchor(note.id)!.x - before!.x,
          closeTo(3, .00001),
        );
        expect(await File('${temp.path}/converted/model.glb').exists(), isTrue);
      }

      await work.save(File('${temp.path}/local.json'));
      expect(await File('${temp.path}/local.json').exists(), isTrue);
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('session-url')),
        server.endpoint.toString(),
      );
      await tester.enterText(
        find.byKey(const Key('session-token')),
        'integration-fixture-token',
      );
      await tester.tap(find.byKey(const Key('connect-session')));
      await settleWork();
      expect(work.session, isNotNull);
      await tester.tap(find.byKey(const Key('sync')));
      await settleWork();
      expect(work.error, contains('403'));
      expect(work.review.document.annotations[note.id]!.text, 'Inspect seal');
      canWrite = true;
      await tester.tap(find.text('Retry'));
      await settleWork();
      expect(work.error, isNull);
      final remote = await store.read();
      await store.compareAndWrite(
        expectedVersion: remote.version,
        document: EngineeringDocument(
          id: 'review',
          objects: remote.document.objects.values,
          annotations: [
            EngineeringAnnotation(
              id: note.id,
              objectId: note.objectId,
              text: 'Remote inspection complete',
              anchor: note.anchor,
            ),
          ],
        ),
      );
      work.putNote('Local inspection pending', existing: note);
      await tester.tap(find.byKey(const Key('sync')));
      await settleWork();
      expect(work.conflicts, hasLength(1));
      final dropdown = find.byType(
        DropdownButtonFormField<EngineeringConflictChoice>,
      );
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('remote').last);
      await tester.pumpAndSettle();
      final apply = find.byKey(const Key('apply-conflicts'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await settleWork();
      expect(work.conflicts, isEmpty);
      expect(
        (await store.read()).document.annotations[note.id]!.text,
        'Remote inspection complete',
      );
      expect(frames.where((f) => f.triangles > 0), isNotEmpty);
      expect(frames.every((f) => f.readbackBytes == 0), isTrue);
      expect(
        frames.every((f) => f.presentationPath != PresentationPath.readback),
        isTrue,
      );
      // ignore: avoid_print
      print(
        'NATIVE_REVIEW backend=metal frames=${frames.length} readbackBytes=0 reload=pass permissions=pass conflict=pass persistence=pass conversion=${python.isNotEmpty ? 'pass' : 'not-requested'}',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      work.dispose();
      await work.controller.whenDisposed;
    },
  );
}
