import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart' show GlobeControls;
import 'package:zyren_geospatial/src/clouds/history.dart';
import 'package:zyren_geospatial/src/clouds/frame.dart';
import 'dart:math' as math;

void main() {
  test('lunar history tolerates parallax but rejects lighting edits', () {
    final history = CloudHistory();
    final camera = PerspectiveCamera();
    CloudHistoryFrame begin({
      int number = 2,
      double lunar = 1e-4,
      double fill = 0,
      Vec3? moon = const Vec3(0, 1, 0),
    }) => history.begin(
      camera: camera,
      aspect: 1,
      width: 64,
      height: 64,
      number: number,
      elapsed: Duration.zero,
      revision: 0,
      epoch: 0,
      sun: const Vec3(1, 0, 0),
      moon: moon,
      lunarIrradiance: lunar,
      nightLightIntensity: fill,
    );
    history.present(begin(number: 1), 0);
    expect(begin(lunar: 1.00001e-4).reason, CloudHistoryReset.none);
    expect(begin(lunar: 1.02e-4).reason, CloudHistoryReset.lighting);
    expect(begin(fill: .1).reason, CloudHistoryReset.lighting);
    expect(begin(moon: const Vec3(0, 0, 1)).reason, CloudHistoryReset.lighting);
    expect(begin(moon: null, lunar: 0).reason, CloudHistoryReset.lighting);
    expect(
      begin().reason,
      CloudHistoryReset.none,
      reason: 'Unpresented lighting changes must not become the baseline.',
    );
  });
  test('globe navigation preserves cloud history while clipping adapts', () {
    for (final depth in DepthStrategy.values) {
      final history = CloudHistory();
      final camera = PerspectiveCamera(
        position: const Vec3(6379137, 0, 0),
        target: const Vec3(6379137, 0, 1000),
        up: const Vec3(1, 0, 0),
        near: 1,
        far: 1e8,
        depthStrategy: depth,
      );
      final controls = GlobeControls(camera)..adjustHeight = false;
      addTearDown(controls.dispose);
      var previousNear = camera.near;
      for (var i = 0; i < 24; i++) {
        camera.position += const Vec3(1, 0, 0);
        camera.target += const Vec3(1, 0, 0);
        controls.update(1 / 60);
        expect(camera.near, isNot(previousNear));
        previousNear = camera.near;
        final frame = history.begin(
          camera: camera,
          aspect: 1,
          width: 640,
          height: 640,
          number: i,
          elapsed: Duration(microseconds: i * 16667),
          revision: 0,
          epoch: 0,
          sun: const Vec3(1, 0, 0),
        );
        expect(frame.valid, i > 0);
        expect(frame.frames, i + 1);
        history.present(frame, 0);
      }
    }
  });
  test('clipping changes preserve history for both camera projections', () {
    for (final depth in DepthStrategy.values) {
      for (final Camera camera in [
        PerspectiveCamera(near: 1, far: 1e7, depthStrategy: depth),
        OrthographicCamera(near: 1, far: 1e7, depthStrategy: depth),
      ]) {
        final history = CloudHistory();
        var number = 0;
        CloudHistoryFrame begin() => history.begin(
          camera: camera,
          aspect: 1,
          width: 32,
          height: 32,
          number: number,
          elapsed: Duration(milliseconds: 16 * number++),
          revision: 0,
          epoch: 0,
          sun: const Vec3(1, 0, 0),
        );
        final first = begin();
        history.present(first, 0);
        switch (camera) {
          case PerspectiveCamera():
            camera.setClippingRange(100, 1e6);
          case OrthographicCamera():
            camera.setClippingRange(100, 1e6);
        }
        final clipped = begin();
        expect(clipped.valid, isTrue);
        expect(clipped.frames, 2);
        expect(
          clipped.viewProjection.storage,
          isNot(first.viewProjection.storage),
        );
        history.present(clipped, 0);
        switch (camera) {
          case PerspectiveCamera():
            camera.zoom = 2;
          case OrthographicCamera():
            camera.zoom = 2;
        }
        expect(begin().reason, CloudHistoryReset.projection);
      }
    }
  });
  test(
    'cloud history commits only successful frames and rejects discontinuities',
    () {
      final history = CloudHistory();
      final camera = PerspectiveCamera(
        position: const Vec3(6360100, 0, 0),
        target: const Vec3(6360100, 0, 1000),
        near: 1,
        far: 1e7,
      );
      var number = 0, revision = 0, epoch = 0;
      var elapsed = Duration.zero;
      var sun = const Vec3(1, 0, 0);
      CloudHistoryFrame begin() => history.begin(
        camera: camera,
        aspect: 1,
        width: 32,
        height: 32,
        number: number++,
        elapsed: elapsed,
        revision: revision,
        epoch: epoch,
        sun: sun,
      );
      final first = begin();
      expect(first.valid, false);
      expect(history.status.accumulatedFrames, 0);
      history.present(first, revision);
      expect(history.status.accumulatedFrames, 1);
      elapsed += const Duration(milliseconds: 16);
      camera.position += const Vec3(0, 1, 0);
      camera.target += const Vec3(0, 1, 0);
      final moving = begin();
      expect(moving.valid, true);
      history.present(moving, revision);
      expect(history.status.accumulatedFrames, 2);
      elapsed += const Duration(milliseconds: 16);
      begin(); // An unpresented frame must not enter history.
      final failed = begin();
      expect(failed.valid, false);
      expect(failed.reason, CloudHistoryReset.failedFrame);
      history.present(failed, revision);
      epoch++;
      expect(begin().reason, CloudHistoryReset.sceneCut);
      final cut = begin();
      history.present(cut, revision);
      camera.position += const Vec3(20000, 0, 0);
      camera.target += const Vec3(20000, 0, 0);
      expect(begin().reason, CloudHistoryReset.cameraCut);
      history.present(begin(), revision);
      camera.fieldOfView = math.pi / 3;
      expect(begin().reason, CloudHistoryReset.projection);
      history.present(begin(), revision);
      sun = const Vec3(0, 1, 0);
      expect(begin().reason, CloudHistoryReset.lighting);
      history.present(begin(), revision);
      elapsed += const Duration(seconds: 2);
      expect(begin().reason, CloudHistoryReset.time);
      history.present(begin(), revision);
      revision++;
      final edited = begin();
      expect(edited.reason, CloudHistoryReset.parameters);
      revision++;
      history.present(edited, revision);
      expect(history.status.valid, false);
    },
  );
  test(
    'previous camera matrix projects relative positions in ECEF and local frames',
    () {
      for (final offset in [Vec3.zero, const Vec3(6360000, 2000, 0)]) {
        for (final depth in DepthStrategy.values) {
          for (final ortho in [false, true]) {
            final Camera previous = ortho
                ? OrthographicCamera(
                    position: offset + const Vec3(100, 0, 0),
                    target: offset + const Vec3(100, 0, 1000),
                    left: -200,
                    right: 200,
                    bottom: -200,
                    top: 200,
                    near: 1,
                    far: 1e6,
                    depthStrategy: depth,
                  )
                : PerspectiveCamera(
                    position: offset + const Vec3(100, 0, 0),
                    target: offset + const Vec3(100, 0, 1000),
                    near: 1,
                    far: 1e6,
                    depthStrategy: depth,
                  );
            final priorMatrix = previous.viewProjection(1),
                priorPosition = previous.position;
            previous.position += const Vec3(5, 0, 0);
            previous.target += const Vec3(5, 0, 0);
            final frame = CloudFrameState(
              camera: previous,
              worldToEcef: Mat4.identity(),
              correctedCamera: const Vec3(6360100, 0, 0),
              sun: const Vec3(1, 0, 0),
              aspect: 1,
              width: 32,
              height: 32,
              shadowSize: 8,
              cascadeCount: 2,
              previousViewProjection: priorMatrix,
              previousCamera: priorPosition,
            );
            final relative =
                const Vec3(0, 0, 1000) + (previous.position - priorPosition);
            final actual = project(
                  Mat4(frame.data.sublist(180, 196)),
                  relative,
                ),
                expected = (
                  ortho
                      ? -5 / 200
                      : -5 /
                            (1000 *
                                math.tan(
                                  (previous as PerspectiveCamera).fieldOfView /
                                      2,
                                )),
                  0.0,
                );
            expect(actual.$1, closeTo(expected.$1, 1e-6));
            expect(actual.$2, closeTo(expected.$2, 1e-6));
          }
        }
      }
    },
  );
}

(double, double) project(Mat4 m, Vec3 p) {
  final v = m.storage;
  final w = v[3] * p.x + v[7] * p.y + v[11] * p.z + v[15];
  return (
    (v[0] * p.x + v[4] * p.y + v[8] * p.z + v[12]) / w,
    (v[1] * p.x + v[5] * p.y + v[9] * p.z + v[13]) / w,
  );
}
