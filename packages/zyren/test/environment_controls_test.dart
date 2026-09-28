import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

Vec3 vector(Object? value) =>
    Vec3.array((value as List).cast<num>().map((v) => v.toDouble()).toList());
void main() {
  for (final speed in [.5, 1.0, 2.0]) {
    for (final input in ['wheel', 'pinch']) {
      for (final zoomIn in [true, false]) {
        test('orthographic environment $input speed=$speed zoomIn=$zoomIn', () {
          final camera = OrthographicCamera(position: const Vec3(40, 60, 100));
          final controls = EnvironmentControls(camera)..enableDamping = true;
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
          expect(camera.zoom, zoomIn ? greaterThan(before) : lessThan(before));
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
        });
      }
    }
  }

  test('wheel uses its own pointer position without a preceding hover', () {
    final a = PerspectiveCamera(position: const Vec3(40, 60, 100));
    final b = PerspectiveCamera(position: const Vec3(40, 60, 100));
    final direct = EnvironmentControls(a), withHover = EnvironmentControls(b);
    addTearDown(direct.dispose);
    addTearDown(withHover.dispose);
    for (final controls in [direct, withHover]) {
      controls.update(1 / 60);
      controls.handleWheel(const ViewportPoint(470, 300), -120);
      controls.update(1 / 60);
    }
    withHover.handlePointer(
      ScenePointerEvent(
        point: const ViewportPoint(200, 220),
        phase: ScenePointerPhase.hover,
        kind: ScenePointerKind.mouse,
      ),
    );
    for (final controls in [direct, withHover]) {
      controls.handleWheel(const ViewportPoint(200, 220), -80);
      controls.update(1 / 60);
    }
    expect(a.position.distanceTo(b.position), lessThan(1e-8));
  });
  final fixture =
      jsonDecode(
            File('test/fixtures/environment_controls.json').readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    test(
      'environment ${row['kind']} ${row['hz']}Hz damp=${row['damping']} ${row['initial']['up']}',
      () {
        final initial = row['initial'];
        final Camera camera = row['kind'] == 'perspective'
            ? PerspectiveCamera(
                position: vector(initial['position']),
                up: vector(initial['up']),
                far: 100000,
              )
            : OrthographicCamera(
                position: vector(initial['position']),
                up: vector(initial['up']),
                left: -80,
                right: 80,
                top: 60,
                bottom: -60,
                far: 100000,
              );
        final controls =
            EnvironmentControls(
                camera,
                viewport: const ViewportMetrics(800, 600, devicePixelRatio: 2),
              )
              ..up = vector(initial['up'])
              ..fallbackPlaneNormal = vector(initial['up'])
              ..enableDamping = row['damping'] as bool;
        addTearDown(controls.dispose);
        final dt = 1 / (row['hz'] as num);
        controls.update(dt);
        final events = <String>[];
        controls.events.listen((event) => events.add(event.name));
        void emit(Map a) {
          final point = ViewportPoint(
            (a['x'] as num? ?? 0).toDouble(),
            (a['y'] as num? ?? 0).toDouble(),
          );
          if (a['type'] == 'wheel') {
            controls.handleWheel(
              point,
              (a['dy'] as num).toDouble(),
              mode: ScrollDeltaMode.values[a['mode'] as int? ?? 0],
            );
          } else {
            controls.handlePointer(
              ScenePointerEvent(
                point: point,
                phase: switch (a['type']) {
                  'down' => ScenePointerPhase.down,
                  'move' => ScenePointerPhase.move,
                  'hover' => ScenePointerPhase.hover,
                  _ => ScenePointerPhase.up,
                },
                pointer: a['id'] as int? ?? 1,
                buttons: a['buttons'] as int? ?? 1,
                kind: a['touch'] == true
                    ? ScenePointerKind.touch
                    : ScenePointerKind.mouse,
                modifiers: {
                  if (a['shift'] == true) SceneModifier.shift,
                  if (a['ctrl'] == true) SceneModifier.control,
                },
              ),
            );
          }
        }

        var index = 0;
        for (final sample in row['trace'] as List) {
          events.clear();
          final action = sample['action'] as Map;
          switch (action['type']) {
            case 'tick':
              break;
            case 'cancel':
              controls.resetState();
            case 'resize':
              controls.viewport = ViewportMetrics(
                (action['width'] as num).toDouble(),
                (action['height'] as num).toDouble(),
                devicePixelRatio: 2,
              );
            case 'batch':
              for (final a in action['points'] as List) {
                emit(a as Map);
              }
            default:
              emit(action);
          }
          controls.update(dt);
          final reason = '$index $action';
          expect(
            camera.position.distanceTo(vector(sample['position'])),
            lessThan(1e-7),
            reason: reason,
          );
          final back = (camera.position - camera.target).normalized();
          expect(
            (-back).distanceTo(vector(sample['forward'])),
            lessThan(1e-9),
            reason: reason,
          );
          expect(
            back
                .cross(camera.up.cross(back).normalized())
                .distanceTo(vector(sample['up'])),
            lessThan(1e-9),
            reason: reason,
          );
          expect(
            controls.pivotPoint.distanceTo(vector(sample['pivot'])),
            lessThan(1e-7),
            reason: reason,
          );
          expect(controls.state.index, sample['state'], reason: reason);
          expect(events, sample['events'], reason: reason);
          final zoom = camera is PerspectiveCamera
              ? camera.zoom
              : (camera as OrthographicCamera).zoom;
          expect(zoom, closeTo(sample['zoom'] as num, 1e-10), reason: reason);
          index++;
        }
      },
    );
  }

  test(
    'height clearance uses the supplied terrain and cancel stops inertia',
    () {
      final camera = PerspectiveCamera(position: const Vec3(0, 3, 10));
      final controls = EnvironmentControls(
        camera,
        surfaceQuery: (ray) {
          final t = (2 - ray.origin.y) / ray.direction.y;
          return t >= 0 ? NavigationHit(ray.at(t), t) : null;
        },
      );
      addTearDown(controls.dispose);
      controls.update(1 / 60);
      expect(camera.position.y, closeTo(7, 1e-8));
      controls.handlePointer(
        ScenePointerEvent(
          point: const ViewportPoint(300, 300),
          phase: ScenePointerPhase.down,
          buttons: 1,
        ),
      );
      controls.handlePointer(
        ScenePointerEvent(
          point: const ViewportPoint(320, 320),
          phase: ScenePointerPhase.move,
        ),
      );
      controls.update(1 / 60);
      controls.handlePointer(
        ScenePointerEvent(
          point: const ViewportPoint(320, 320),
          phase: ScenePointerPhase.cancel,
        ),
      );
      final position = camera.position;
      controls.update(1 / 60);
      expect(camera.position, position);
      expect(controls.needsUpdate, isFalse);
      expect(controls.state, EnvironmentState.none);
    },
  );
}
