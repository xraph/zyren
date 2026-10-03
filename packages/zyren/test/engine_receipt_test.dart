import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'engine_output_test.dart' show SurfaceBackend;

void main() {
  test('pre-publication backend failure sends no successful receipt', () async {
    final backend = _RejectedBackend();
    final observer = _Receipt('observer');
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      backendFactory: () async => backend,
      plugins: [observer],
    );
    try {
      await expectLater(
        engine.renderFrame(
          elapsed: Duration.zero,
          width: 16,
          height: 16,
          target: SurfaceTarget(backend.key, 0),
        ),
        throwsStateError,
      );
      expect(observer.stats, isEmpty);
    } finally {
      await engine.dispose();
    }
  });
  test(
    'successful receipts reach all hooks before the first hook error escapes',
    () async {
      final backend = SurfaceBackend();
      final first = _Receipt('first')..error = StateError('first hook failure');
      final second = _Receipt('second')
        ..error = StateError('second hook failure');
      final last = _Receipt('last');
      var invalidations = 0;
      backend.admission = SceneAdmission(
        candidateReady: false,
        publishedRevision: 1,
        uploadBacklogBytes: 100,
        stagedBytes: 100,
        presentedIdentities: [],
      );
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [first, second, last],
        onInvalidate: () {
          invalidations++;
          if (first.error != null) throw StateError('invalidate failure');
        },
      );
      Future<FrameOutput> render() => engine.renderFrame(
        elapsed: Duration.zero,
        width: 16,
        height: 16,
        target: SurfaceTarget(backend.key, 0),
      );
      try {
        await expectLater(render(), throwsA(same(first.error)));
        expect(first.stats.length, 1);
        expect(second.stats.length, 1);
        expect(last.stats.length, 1);
        expect(last.stats.single, same(first.stats.single));
        expect(invalidations, 1);
        first.error = null;
        second.error = null;
        await render();
        expect(last.stats.length, 2);
      } finally {
        await engine.dispose();
      }
    },
  );
}

final class _Receipt extends ScenePlugin {
  @override
  final String id;
  final stats = <FrameStats>[];
  Object? error;
  _Receipt(this.id);
  @override
  Future<void> afterRender(
    PluginContext context,
    FrameInfo frame,
    FrameStats value,
  ) async {
    stats.add(value);
    await Future<void>.value();
    if (error case final failure?) throw failure;
  }
}

final class _RejectedBackend extends SurfaceBackend {
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    throw StateError('rejected before publication');
  }
}
