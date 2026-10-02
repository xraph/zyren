import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

Vec3 vector(Object? value) =>
    Vec3.array((value as List).cast<num>().map((n) => n.toDouble()).toList());
void nearVector(Vec3 actual, Object? expected, String reason) {
  final want = vector(expected);
  for (var i = 0; i < 3; i++) {
    expect(actual.storage[i], closeTo(want.storage[i], 1e-7), reason: reason);
  }
}

void main() {
  final fixture =
      jsonDecode(
            File('test/fixtures/camera_transition.json').readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    test(
      'transition reference ${row['hz']}Hz positional=${row['positionalZoom']} ${row['initial']['up']}',
      () {
        final initial = row['initial'];
        final perspective = PerspectiveCamera(
          position: vector(initial['position']),
          target: vector(initial['target']),
          up: vector(initial['up']),
          near: .1,
          far: 100000,
        );
        final orthographic = OrthographicCamera(
          position: const Vec3(0, 0, 1000),
          left: -3,
          right: 3,
          top: 2,
          bottom: -2,
          near: .5,
          far: 200000,
        );
        final manager = CameraTransitionManager(perspective, orthographic)
          ..fixedPoint = vector(initial['fixed'])
          ..orthographicPositionalZoom = row['positionalZoom'] as bool;
        addTearDown(manager.dispose);
        final events = <String>[];
        manager.events.listen((event) => events.add(event.type.wireName));
        for (final step in row['steps'] as List) {
          events.clear();
          if (step['action'] == 'toggle') {
            manager.toggle();
          } else {
            manager.update((step['dt'] as num).toDouble());
          }
          final c = manager.camera;
          final reason =
              '${row['hz']} ${step['action']} alpha=${step['alpha']}';
          final back = (c.position - c.target).normalized();
          final right = c.up.cross(back).normalized();
          nearVector(c.position, step['position'], reason);
          nearVector(-back, step['forward'], reason);
          nearVector(back.cross(right), step['up'], reason);
          expect(
            manager.alpha,
            closeTo(step['alpha'] as num, 1e-12),
            reason: reason,
          );
          expect(manager.animating, step['animating'], reason: reason);
          expect(events, step['events'], reason: reason);
          expect(
            identical(c, perspective)
                ? 'perspective'
                : identical(c, orthographic)
                ? 'orthographic'
                : 'transition',
            step['kind'],
          );
          if (c is PerspectiveCamera) {
            expect(c.fieldOfView, closeTo(step['fov'] as num, 1e-12));
            expect(c.near, closeTo(step['near'] as num, 1e-7));
            expect(c.far, closeTo(step['far'] as num, 1e-7));
            expect(c.zoom, closeTo(step['zoom'] as num, 1e-12));
          } else if (c is OrthographicCamera) {
            expect(c.near, closeTo(step['near'] as num, 1e-7));
            expect(c.far, closeTo(step['far'] as num, 1e-7));
            expect(c.zoom, closeTo(step['zoom'] as num, 1e-12));
          }
        }
      },
    );
  }

  test('transition keeps an off-axis fixed point stable', () {
    final p = PerspectiveCamera(position: const Vec3(0, 0, 100), far: 1e6);
    final manager = CameraTransitionManager(p, OrthographicCamera(far: 1e6))
      ..fixedPoint = const Vec3(2, 3, 0);
    addTearDown(manager.dispose);
    final before = p.projectPoint(manager.fixedPoint, 1);
    manager.toggle();
    for (var i = 0; i < 20; i++) {
      manager.update(.01);
      final projected = manager.camera.projectPoint(manager.fixedPoint, 1);
      expect(projected.x, closeTo(before.x, 1e-10));
      expect(projected.y, closeTo(before.y, 1e-10));
    }
  });

  test('transition rejects invalid settings and use after disposal', () {
    final manager = CameraTransitionManager();
    for (final dt in [-1.0, double.nan, double.infinity]) {
      expect(() => manager.update(dt), throwsArgumentError);
    }
    expect(() => manager.duration = Duration.zero, throwsArgumentError);
    expect(
      () => manager.fixedPoint = const Vec3(double.nan, 0, 0),
      throwsArgumentError,
    );
    expect(
      () => manager.orthographicOffset = double.infinity,
      throwsArgumentError,
    );
    manager.easeFunction = (_) => double.nan;
    manager.toggle();
    expect(() => manager.update(.1), throwsArgumentError);
    manager.dispose();
    manager.dispose();
    expect(manager.toggle, throwsStateError);
    expect(() => manager.update(.1), throwsStateError);
    expect(manager.syncCameras, throwsStateError);
  });
}
