import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'support/load_task_fixture.dart';
import 'support/fakes.dart';

void main() {
  test(
    'reentrant stream attachment still cancels the rejected subscription',
    () async {
      final scope = AttachmentScope();
      var cancelled = false;
      final stream = StreamController<int>(
        sync: true,
        onListen: scope.close,
        onCancel: () {
          cancelled = true;
        },
      );
      expect(() => scope.listen(stream.stream, (_) {}), throwsStateError);
      expect(cancelled, isTrue);
      await stream.close();
    },
  );
  test(
    'async close callbacks stop immediately and join cleanup failures',
    () async {
      final scope = AttachmentScope();
      final gate = Completer<void>();
      final events = <int>[];
      scope.onClose(() {
        events.add(1);
        throw StateError('cleanup');
      });
      scope.onClose(() {
        events.add(2);
        return gate.future;
      });
      scope.close();
      expect(events, [2, 1]);
      var completed = false;
      final outcome = expectLater(
        scope.whenClosed,
        throwsA(isA<ScopeCleanupException>()),
      );
      scope.whenClosed.then<void>(
        (_) {
          completed = true;
        },
        onError: (Object _, StackTrace _) {
          completed = true;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      gate.complete();
      await outcome;
      expect(() => scope.onClose(() {}), throwsStateError);
    },
  );
  test(
    'asynchronous cancellation errors join cleanup failures without skipping owners',
    () async {
      final gate = Completer<void>();
      final stream = StreamController<int>(onCancel: () => gate.future);
      final events = <String>[];
      final renderer = TestRenderer(events);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        plugins: [
          TestPlugin(
            'listener',
            events,
            onAttach: (context) {
              context.scope.listen(stream.stream, (_) {});
            },
            onDetach: (_) => throw StateError('detach failed'),
          ),
        ],
      );
      final closed = expectLater(
        engine.dispose(),
        throwsA(
          isA<EngineCleanupException>().having(
            (error) => error.errors.length,
            'failures',
            2,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(renderer.disposals, 0);
      gate.completeError(StateError('cancel failed'));
      await closed;
      expect(renderer.disposals, 1);
      await stream.close();
    },
  );
  test(
    'lifetime closure waits for the current frame before plugin resource teardown',
    () async {
      final lifetime = AttachmentScope();
      final gate = Completer<void>();
      final events = <String>[];
      final renderer = TestRenderer(events, gate: gate);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        lifetime: lifetime,
        plugins: [TestPlugin('resource', events)],
      );
      final frame = engine.render(elapsed: Duration.zero, width: 4, height: 4);
      await Future<void>.delayed(Duration.zero);
      lifetime.close();
      await expectLater(
        engine.render(elapsed: Duration.zero, width: 4, height: 4),
        throwsStateError,
      );
      expect(events, isNot(contains('resource.detach')));
      gate.complete();
      await frame;
      await engine.dispose();
      expect(events, contains('resource.detach'));
      expect(renderer.disposals, 1);
    },
  );

  test(
    'engine awaits asynchronous subscription cancellation before detaching resources',
    () async {
      final gate = Completer<void>();
      final stream = StreamController<int>(onCancel: () => gate.future);
      final events = <String>[];
      final renderer = TestRenderer(events);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        plugins: [
          TestPlugin(
            'listener',
            events,
            onAttach: (context) {
              context.scope.listen(stream.stream, (_) {});
            },
          ),
        ],
      );
      var done = false;
      final closing = engine.dispose().then((_) {
        done = true;
      });
      await Future<void>.delayed(Duration.zero);
      final completedEarly = done;
      final detachedEarly = events.contains('listener.detach');
      gate.complete();
      await closing;
      await stream.close();
      expect(completedEarly, isFalse);
      expect(detachedEarly, isFalse);
      expect(renderer.disposals, 1);
    },
  );
  test(
    'closing a live engine lifetime stops new rendering and disposes it',
    () async {
      final lifetime = AttachmentScope();
      final renderer = TestRenderer([]);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        lifetime: lifetime,
      );
      lifetime.close();
      await expectLater(
        engine.render(elapsed: Duration.zero, width: 4, height: 4),
        throwsStateError,
      );
      await engine.dispose();
      expect(renderer.renders, 0);
      expect(renderer.disposals, 1);
    },
  );

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
