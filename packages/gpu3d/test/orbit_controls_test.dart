import 'dart:convert';
import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

Vec3 vector(dynamic values) =>
    Vec3.array((values as List).map((v) => (v as num).toDouble()).toList());

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/stdlib_orbit.json').readAsStringSync())
          as Map;
  for (final row in fixture['rows'] as List) {
    test('stdlib replay: ${row['kind']} ${row['up']} ${row['name']}', () async {
      final origin = row['origin'] == null ? Vec3.zero : vector(row['origin']);
      final Camera camera = row['kind'] == 'perspective'
          ? PerspectiveCamera(
              position: origin + const Vec3(4, 6, 10),
              up: vector(row['up']),
              near: 1,
              far: 10000,
            )
          : OrthographicCamera(
              position: origin + const Vec3(4, 6, 10),
              up: vector(row['up']),
              left: -8,
              right: 8,
              top: 6,
              bottom: -6,
              far: 10000,
            );
      final controls = OrbitControls(
        camera,
        target: origin,
        viewport: const ViewportMetrics(800, 600),
      );
      final options = row['options'] as Map;
      controls.enableDamping = options['enableDamping'] ?? false;
      controls.autoRotate = options['autoRotate'] ?? false;
      controls.zoomToCursor = options['zoomToCursor'] ?? false;
      controls.screenSpacePanning = options['screenSpacePanning'] ?? true;
      controls.reverseOrbit = options['reverseOrbit'] ?? false;
      controls.minDistance = (options['minDistance'] as num?)?.toDouble() ?? 0;
      controls.maxDistance =
          (options['maxDistance'] as num?)?.toDouble() ?? double.infinity;
      controls.minZoom = (options['minZoom'] as num?)?.toDouble() ?? 0;
      controls.maxZoom =
          (options['maxZoom'] as num?)?.toDouble() ?? double.infinity;
      controls.minPolarAngle =
          (options['minPolarAngle'] as num?)?.toDouble() ??
          controls.minPolarAngle;
      controls.maxPolarAngle =
          (options['maxPolarAngle'] as num?)?.toDouble() ??
          controls.maxPolarAngle;
      controls.minAzimuthAngle =
          (options['minAzimuthAngle'] as num?)?.toDouble() ??
          controls.minAzimuthAngle;
      controls.maxAzimuthAngle =
          (options['maxAzimuthAngle'] as num?)?.toDouble() ??
          controls.maxAzimuthAngle;
      controls.rotateSpeed = (options['rotateSpeed'] as num?)?.toDouble() ?? 1;
      controls.panSpeed = (options['panSpeed'] as num?)?.toDouble() ?? 1;
      controls.zoomSpeed = (options['zoomSpeed'] as num?)?.toDouble() ?? 1;
      if (row['map'] == true) {
        controls.primary = OrbitAction.pan;
        controls.secondary = OrbitAction.rotate;
        controls.oneTouch = OrbitAction.pan;
        controls.twoTouch = OrbitAction.dollyRotate;
      }
      controls.update();
      if (row['origin'] != null) controls.saveState();
      const tolerance = 1e-8;
      var maxPositionError = 0.0;
      final events = <String>[];
      final subscription = controls.events.listen(
        (event) => events.add(event.name),
      );
      var index = 0;
      for (final step in row['trace'] as List) {
        final action = step['action'] as Map;
        final reason = 'step ${index++}: $action';
        switch (action['type']) {
          case 'tick':
            controls.update();
          case 'save':
            controls.saveState();
          case 'reset':
            controls.reset();
          case 'polar':
            controls.setPolarAngle((action['value'] as num).toDouble());
          case 'azimuth':
            controls.setAzimuthalAngle((action['value'] as num).toDouble());
          case 'in':
            controls.dollyIn((action['factor'] as num).toDouble());
          case 'out':
            controls.dollyOut((action['factor'] as num).toDouble());
          case 'scale':
            controls.setScale((action['value'] as num).toDouble());
          case 'resize':
            controls.viewport = ViewportMetrics(
              (action['width'] as num).toDouble(),
              (action['height'] as num).toDouble(),
            );
          case 'key':
            controls.handleKey(
              SceneKeyEvent(
                action['code'] == 'ArrowLeft'
                    ? SceneKey.arrowLeft
                    : SceneKey.arrowUp,
                SceneKeyPhase.down,
                modifiers: {if (action['shift'] == true) SceneModifier.shift},
              ),
            );
          default:
            controls.handlePointer(
              ScenePointerEvent(
                point: ViewportPoint(
                  (action['x'] as num?)?.toDouble() ?? 0,
                  (action['y'] as num?)?.toDouble() ?? 0,
                ),
                phase: switch (action['type']) {
                  'down' => ScenePointerPhase.down,
                  'move' => ScenePointerPhase.move,
                  'up' => ScenePointerPhase.up,
                  'cancel' => ScenePointerPhase.cancel,
                  'wheel' => ScenePointerPhase.scroll,
                  _ => throw StateError('$action'),
                },
                pointer: action['id'] ?? 1,
                kind: action['touch'] == true
                    ? ScenePointerKind.touch
                    : ScenePointerKind.mouse,
                buttons: switch (action['button'] ?? 0) {
                  0 => 1,
                  1 => 4,
                  _ => 2,
                },
                modifiers: {if (action['shift'] == true) SceneModifier.shift},
                delta: ViewportPoint(
                  0,
                  (action['dy'] as num?)?.toDouble() ?? 0,
                ),
              ),
            );
        }
        final positionError = camera.position.distanceTo(
          vector(step['position']),
        );
        if (positionError > maxPositionError) maxPositionError = positionError;
        expect(positionError, lessThan(tolerance), reason: '$reason position');
        expect(
          controls.target.distanceTo(vector(step['target'])),
          lessThan(tolerance),
          reason: '$reason target',
        );
        expect(
          controls.zoom,
          closeTo(step['zoom'], 1e-12),
          reason: '$reason zoom',
        );
        final q = camera.quaternion, expected = step['quaternion'] as List;
        final dot =
            q.x * expected[0] +
            q.y * expected[1] +
            q.z * expected[2] +
            q.w * expected[3];
        expect(dot.abs(), closeTo(1, 1e-12), reason: '$reason quaternion');
        expect(events, step['events'], reason: '$reason events');
        events.clear();
      }
      await subscription.cancel();
      controls.dispose();
      if (row['origin'] != null) {
        print('Earth orbit maximum position error: $maxPositionError');
      }
    });
  }
}
