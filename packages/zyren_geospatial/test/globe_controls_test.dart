import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

List<double> numbers(Object? value) =>
    (value as List).cast<num>().map((v) => v.toDouble()).toList();
Vec3 vector(Object? value) => Vec3.array(numbers(value));
void main() {
  for (final near in [true, false]) {
    for (final speed in [.5, 1.0, 2.0]) {
      for (final input in ['wheel', 'pinch']) {
        for (final zoomIn in [true, false]) {
          test(
            'orthographic globe near=$near $input speed=$speed zoomIn=$zoomIn',
            () {
              final camera = OrthographicCamera(
                position: const Vec3(19000000, 0, 0),
                up: const Vec3(0, 0, 1),
                left: -800,
                right: 800,
                top: 600,
                bottom: -600,
                far: 1e9,
                zoom: near ? .001 : .00015,
              );
              final controls = GlobeControls(camera)..enableDamping = true;
              expect(controls.isNearControls, near);
              controls.zoomSpeed = speed;
              addTearDown(controls.dispose);
              controls.update(1 / 60);
              final before = camera.zoom;
              if (input == 'wheel') {
                controls.handleWheel(
                  const ViewportPoint(400, 300),
                  zoomIn ? -40 : 40,
                );
              } else {
                void touch(int id, double x, ScenePointerPhase phase) =>
                    controls.handlePointer(
                      ScenePointerEvent(
                        point: ViewportPoint(x, 300),
                        pointer: id,
                        phase: phase,
                        buttons: 1,
                        kind: ScenePointerKind.touch,
                      ),
                    );
                touch(1, 350, ScenePointerPhase.down);
                touch(2, 450, ScenePointerPhase.down);
                controls.update(1 / 60);
                touch(1, zoomIn ? 340 : 360, ScenePointerPhase.move);
                touch(2, zoomIn ? 460 : 440, ScenePointerPhase.move);
              }
              controls.update(1 / 60);
              expect(
                camera.zoom,
                zoomIn ? greaterThan(before) : lessThan(before),
              );
              final exponent = (input == 'wheel' ? .5 : 1.0) * speed;
              final normalized = math.pow(.95, exponent).toDouble();
              expect(
                camera.zoom / before,
                closeTo(zoomIn ? 1 / normalized : normalized, 1e-12),
              );
              // A stationary pinch can still wake a frame; it must not change zoom.
              final stationary = camera.zoom;
              controls.wake();
              controls.update(1 / 60);
              expect(camera.zoom, stationary);
              controls.cancel();
              for (var frame = 0; frame < 30; frame++) {
                controls.update(1 / 60);
              }
              expect(camera.zoom, stationary);
              expect(controls.needsUpdate, isFalse);
            },
          );
        }
      }
    }
  }
  test('top-down tilt clamp preserves an orthonormal camera frame', () {
    final camera = PerspectiveCamera(
      position: const Vec3(6900000, 640000, 640000),
      target: const Vec3(6378137, 0, 0),
      up: const Vec3(0, 0, 1),
      far: 1e9,
    );
    final controls = GlobeControls(camera)..enableDamping = true;
    addTearDown(controls.dispose);
    controls.update(1 / 60);
    controls.handlePointer(
      ScenePointerEvent(
        point: const ViewportPoint(400, 300),
        phase: ScenePointerPhase.down,
        buttons: 2,
      ),
    );
    controls.handlePointer(
      ScenePointerEvent(
        point: const ViewportPoint(425, 330),
        phase: ScenePointerPhase.move,
        buttons: 2,
      ),
    );
    controls.update(1 / 60);
    controls.handlePointer(
      ScenePointerEvent(
        point: const ViewportPoint(425, 330),
        phase: ScenePointerPhase.up,
      ),
    );
    for (var i = 0; i < 300; i++) {
      controls.update(1 / 60);
      final forward = controls.forward, right = controls.right;
      expect(forward.length, closeTo(1, 1e-12));
      expect(right.length, closeTo(1, 1e-12));
      expect(forward.dot(right).abs(), lessThan(1e-12));
      expect(camera.up.dot(forward).abs(), lessThan(1e-10));
      expect(
        camera.viewProjection(4 / 3).storage.every((v) => v.isFinite),
        isTrue,
      );
    }
    expect(controls.needsUpdate, isFalse);
  });
  test('uniform world scale scales the globe clipping distances', () {
    final a = PerspectiveCamera(
      position: const Vec3(19000000, 640000, 640000),
      far: 1e9,
    );
    final b = PerspectiveCamera(position: a.position * 2, far: 1e9);
    final original = GlobeControls(a),
        scaled = GlobeControls(
          b,
          ellipsoidFrame: Mat4.compose(
            Vec3.zero,
            Quat.identity,
            const Vec3(2, 2, 2),
          ),
        );
    addTearDown(original.dispose);
    addTearDown(scaled.dispose);
    original.update(1 / 60);
    scaled.update(1 / 60);
    expect(b.near, closeTo(a.near * 2, 1e-6));
    expect(b.far - .1, closeTo((a.far - .1) * 2, 1e-6));
  });
  test('invalid ellipsoid frames fail before replacing the current frame', () {
    final controls = GlobeControls(
      PerspectiveCamera(
        position: const Vec3(1e7, 0, 0),
        up: const Vec3(0, 0, 1),
        far: 1e9,
      ),
    );
    final before = controls.ellipsoidFrame;
    expect(
      () => controls.ellipsoidFrame = Mat4.compose(
        Vec3.zero,
        Quat.identity,
        const Vec3(1, 2, 1),
      ),
      throwsArgumentError,
    );
    expect(controls.ellipsoidFrame, same(before));
    controls.dispose();
    expect(() => controls.ellipsoidFrame = Mat4.identity(), throwsStateError);
  });
  final fixture =
      jsonDecode(File('test/fixtures/globe_controls.json').readAsStringSync())
          as Map;
  for (final row in fixture['cases'] as List) {
    test(
      'globe ${row['kind']} ${row['hz']} near=${row['near']} transformed=${row['transformed']}',
      () {
        final initial = row['initial'];
        final Camera camera = row['kind'] == 'perspective'
            ? PerspectiveCamera(
                position: vector(initial['position']),
                target: vector(initial['target']),
                up: vector(initial['up']),
                far: 1e9,
              )
            : OrthographicCamera(
                position: vector(initial['position']),
                target: vector(initial['target']),
                up: vector(initial['up']),
                left: -800,
                right: 800,
                top: 600,
                bottom: -600,
                far: 1e9,
                zoom: (initial['zoom'] as num).toDouble(),
              );
        final radii = numbers(row['radii']);
        final controls = GlobeControls(
          camera,
          ellipsoid: Ellipsoid(radii[0], radii[1], radii[2]),
          ellipsoidFrame: Mat4(numbers(initial['frame'])),
        )..enableDamping = true;
        addTearDown(controls.dispose);
        final dt = 1 / (row['hz'] as num);
        controls.update(dt);
        final events = <String>[];
        controls.events.listen((event) => events.add(event.name));
        var index = 0;
        for (final sample in row['trace'] as List) {
          events.clear();
          final action = sample['action'] as Map;
          if (action['type'] == 'resize') {
            controls.viewport = ViewportMetrics(
              (action['width'] as num).toDouble(),
              (action['height'] as num).toDouble(),
            );
          } else if (action['type'] == 'wheel') {
            controls.handleWheel(
              ViewportPoint(
                (action['x'] as num).toDouble(),
                (action['y'] as num).toDouble(),
              ),
              (action['dy'] as num).toDouble(),
            );
          } else if (!['tick', 'initial'].contains(action['type'])) {
            for (final action
                in action['type'] == 'batch'
                    ? (action['points'] as List).cast<Map>()
                    : [action]) {
              controls.handlePointer(
                ScenePointerEvent(
                  point: ViewportPoint(
                    (action['x'] as num? ?? 0).toDouble(),
                    (action['y'] as num? ?? 0).toDouble(),
                  ),
                  phase: switch (action['type']) {
                    'down' => ScenePointerPhase.down,
                    'move' => ScenePointerPhase.move,
                    'hover' => ScenePointerPhase.hover,
                    _ => ScenePointerPhase.up,
                  },
                  buttons: action['buttons'] as int? ?? 1,
                  kind: action['touch'] == true
                      ? ScenePointerKind.touch
                      : ScenePointerKind.mouse,
                  pointer: action['id'] as int? ?? 1,
                ),
              );
            }
          }
          if (action['type'] != 'initial') controls.update(dt);
          final reason = '$index $action';
          expect(
            camera.position.distanceTo(vector(sample['position'])),
            lessThan(1e-4),
            reason: reason,
          );
          final back = (camera.position - camera.target).normalized();
          expect(
            (-back).distanceTo(vector(sample['forward'])),
            lessThan(1e-8),
            reason: reason,
          );
          expect(
            back
                .cross(camera.up.cross(back).normalized())
                .distanceTo(vector(sample['up'])),
            lessThan(1e-8),
            reason: reason,
          );
          final near = camera is PerspectiveCamera
              ? camera.near
              : (camera as OrthographicCamera).near;
          final far = camera is PerspectiveCamera
              ? camera.far
              : (camera as OrthographicCamera).far;
          final zoom = camera is PerspectiveCamera
              ? camera.zoom
              : (camera as OrthographicCamera).zoom;
          expect(near, closeTo(sample['near'] as num, 1e-4), reason: reason);
          expect(far, closeTo(sample['far'] as num, 1e-4), reason: reason);
          expect(zoom, closeTo(sample['zoom'] as num, 1e-12), reason: reason);
          expect(controls.state.index, sample['state'], reason: reason);
          expect(events, sample['events'], reason: reason);
          index++;
        }
      },
    );
  }
}
