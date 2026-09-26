import 'dart:async';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'support/load_task_fixture.dart';
import 'support/fakes.dart';

void main() {
  test(
    'a lifetime does not mask a genuine attach failure as cancellation',
    () async {
      final error = StateError('attach failed');
      final events = <String>[];
      final lifetime = AttachmentScope();
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => TestRenderer(events),
          lifetime: lifetime,
          plugins: [TestPlugin('broken', events, onAttach: (_) => throw error)],
        ),
        throwsA(same(error)),
      );
      lifetime.close();
    },
  );
  test(
    'attachment closes every registration in reverse order, even after errors',
    () {
      final events = <int>[];
      final scope = AttachmentScope();
      final first = scope.keep(Registration(() => events.add(1)));
      final second = scope.keep(
        Registration(() {
          events.add(2);
          throw StateError('cleanup');
        }),
      );
      expect(scope.close, throwsA(isA<ScopeCleanupException>()));
      scope.close();
      first.dispose();
      second.dispose();
      expect(events, [2, 1]);
      final late = Registration(() => events.add(3));
      expect(() => scope.keep(late), throwsStateError);
      expect(late.isDisposed, isTrue);
      expect(events, [2, 1, 3]);
    },
  );
  test('cancel wins before result publication and progress closes', () async {
    final completion = Completer<int>();
    final task = pendingLoadTask(completion.future);
    final result = expectLater(task.result, throwsA(isA<LoadCancelled>()));
    task.cancel();
    task.cancel();
    completion.complete(7);
    await result;
    expect(await task.progress.isEmpty, isTrue);
  });
  test('cancel before a completed source is delivered still wins', () async {
    final completion = Completer<int>();
    final task = pendingLoadTask(completion.future);
    completion.complete(7);
    task.cancel();
    await expectLater(task.result, throwsA(isA<LoadCancelled>()));
  });
  test('successful result is stable after cancellation', () async {
    final task = pendingLoadTask(Future.value(7));
    expect(await task.result, 7);
    task.cancel();
    expect(await task.result, 7);
    expect(await task.progress.isEmpty, isTrue);
  });
  test('asset close cancels pending work and drops retained values', () async {
    final scope = AssetScope();
    final completion = Completer<int>();
    final task = scope.keep(pendingLoadTask(completion.future));
    final result = expectLater(task.result, throwsA(isA<LoadCancelled>()));
    await scope.close();
    await scope.close();
    completion.complete(9);
    await result;
    expect(scope.isClosed, isTrue);
    final late = pendingLoadTask(Future.value(2));
    final lateResult = expectLater(late.result, throwsA(isA<LoadCancelled>()));
    expect(() => scope.keep(late), throwsStateError);
    await lateResult;
  });
  test(
    'engine cancellation closes attachment scope before late attach returns',
    () async {
      final entered = Completer<void>(), finish = Completer<void>();
      final cancellation = AttachmentScope();
      final events = <String>[];
      var releases = 0;
      final renderer = TestRenderer(events);
      final plugin = TestPlugin(
        'pending',
        events,
        onAttach: (context) async {
          context.scope.keep(Registration(() => releases++));
          entered.complete();
          await finish.future;
          context.scope.keep(Registration(() => releases++));
        },
      );
      final engine = SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        plugins: [plugin],
        lifetime: cancellation,
      );
      final failed = expectLater(
        engine,
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.disposed,
          ),
        ),
      );
      await entered.future;
      cancellation.close();
      expect(releases, 1);
      finish.complete();
      await failed;
      expect(releases, 2);
      expect(renderer.disposals, 1);
    },
  );
}
