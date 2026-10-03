import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_capture/sensors.dart';
import 'capture_test.dart' show FixtureBackend;

void main() {
  SensorCaptureRequest request(int tick, {bool depth = false}) =>
      SensorCaptureRequest(
        id: 'r$tick',
        tick: tick,
        scene: Scene(),
        camera: PerspectiveCamera(
          position: const Vec3(0, 0, 5),
          target: Vec3.zero,
        ),
        size: PhysicalSize(8, 8),
        depth: depth,
      );

  test(
    'unsupported depth fails before rendering, never supplies zero distances',
    () async {
      final backend = FixtureBackend();
      final pool = SensorCapturePool(openBackend: () async => backend);
      addTearDown(pool.close);
      await expectLater(
        pool.capture(request(1, depth: true)),
        throwsUnsupportedError,
      );
      expect(backend.submissions, isEmpty);
    },
  );
  test(
    'persistent session pins snapshots and cancels only after completion',
    () async {
      final gate = Completer<void>();
      final backend = FixtureBackend(beforeReturn: () => gate.future);
      var opens = 0;
      final pool = SensorCapturePool(
        openBackend: () async {
          opens++;
          return backend;
        },
        maxPending: 1,
      );
      final r = request(3);
      final first = pool.capture(r);
      first.ignore();
      await Future<void>.delayed(Duration.zero);
      expect(backend.submissions.single, same(r.submission));
      pool.cancel(r.id);
      expect(pool.pendingCount, 1);
      await expectLater(pool.capture(request(4)), throwsStateError);
      final closing = pool.close();
      expect(backend.closes, 0);
      gate.complete();
      await expectLater(first, throwsA(isA<SensorCaptureCancelled>()));
      await closing;
      await pool.close();
      expect(backend.closes, 1);
      expect(opens, 1);
      expect(pool.pendingCount, 0);
    },
  );
  test('capture receipts correlate ticks, size and immutable camera', () async {
    final backend = FixtureBackend();
    final pool = SensorCapturePool(openBackend: () async => backend);
    addTearDown(pool.close);
    final a = await pool.capture(request(10));
    final b = await pool.capture(request(11));
    expect(a.tick, 10);
    expect(b.tick, 11);
    expect(a.requestId, 'r10');
    expect(b.frameId, 2);
    expect(a.width, 8);
    expect(a.colorSpace, ColorSpace.srgb);
    expect(() => a.camera.viewProjection[0] = 0, throwsUnsupportedError);
    expect(a.depth, isNull);
    expect(a.near, .1);
    expect(a.far, 1000);
    expect(a.toJson()['near'], .1);
    expect(pool.reservedBytes, 0);
  });
  test(
    'close racing recreation closes one backend and never reopens',
    () async {
      final gate = Completer<void>();
      final backend = FixtureBackend(beforeReturn: () => gate.future);
      var opens = 0;
      final pool = SensorCapturePool(
        openBackend: () async {
          opens++;
          return backend;
        },
      );
      final pending = pool.capture(request(1));
      pending.ignore();
      await Future<void>.delayed(Duration.zero);
      final recreating = pool.recreate();
      final closing = pool.close();
      gate.complete();
      await expectLater(pending, throwsA(isA<SensorCaptureCancelled>()));
      await recreating;
      await closing;
      expect(backend.closes, 1);
      expect(opens, 1);
      await expectLater(pool.capture(request(2)), throwsStateError);
    },
  );
  test(
    'failed backend startup can recreate and close without duplicate errors',
    () async {
      var attempts = 0;
      final backend = FixtureBackend();
      final pool = SensorCapturePool(
        openBackend: () async {
          if (++attempts == 1) throw StateError('startup');
          return backend;
        },
      );
      await expectLater(pool.capture(request(1)), throwsStateError);
      await pool.recreate();
      expect((await pool.capture(request(2))).resourceGeneration, 1);
      await pool.close();
      expect(backend.closes, 1);
    },
  );
}
