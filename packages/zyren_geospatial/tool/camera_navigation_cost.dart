import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/history.dart';

void main() {
  final scene = Scene();
  for (var i = 0; i < 8; i++) {
    scene.add(
      Mesh(
        SphereGeometry(radius: 10, widthSegments: 128, heightSegments: 64),
        UnlitMaterial(),
      )..position = Vec3(i * 25.0, 0, 0),
    );
  }
  final picker = Raycaster();
  const origin = Vec3(0, 0, 30), direction = Vec3(0, 0, -1);
  final ray = Ray(origin, direction);
  final cameraRay = CameraRay(origin, direction);
  void measure(String name, void Function() run) {
    for (var i = 0; i < 4; i++) {
      run();
    }
    final times = <double>[];
    for (var i = 0; i < 20; i++) {
      final watch = Stopwatch()..start();
      run();
      times.add(watch.elapsedMicroseconds / 1000);
    }
    times.sort();
    print(
      jsonEncode({'case': name, 'medianMs': times[10], 'p95Ms': times[19]}),
    );
  }

  measure('navigation intersectScene', () {
    picker.intersectScene(scene, cameraRay);
  });
  measure('same ray using retained capture cache', () {
    picker.capture(scene, ray).intersectAll();
  });
  final report = picker.capture(scene, ray).trace();
  print(
    jsonEncode({
      'warmGeometryBuilds': report.statistics.geometryBuilds,
      'warmSceneBuilds': report.statistics.sceneBuilds,
    }),
  );
  final camera = PerspectiveCamera(
    position: const Vec3(6379137, 0, 0),
    target: const Vec3(6379137, 0, 1000),
    up: const Vec3(1, 0, 0),
    near: 1,
    far: 1e8,
  );
  final controls = GlobeControls(camera)..adjustHeight = false;
  final history = CloudHistory();
  void frame(int n) {
    controls.update(1 / 60);
    final h = history.begin(
      camera: camera,
      aspect: 1,
      width: 640,
      height: 640,
      number: n,
      elapsed: Duration(microseconds: n * 16667),
      revision: 0,
      epoch: 0,
      sun: const Vec3(1, 0, 0),
    );
    history.present(h, 0);
    print(
      jsonEncode({
        'frame': n,
        'near': camera.near,
        'far': camera.far,
        'historyReason': h.reason.name,
        'accumulated': h.frames,
      }),
    );
  }

  frame(0);
  frame(1);
  for (var n = 2; n < 6; n++) {
    camera.position += const Vec3(1, 0, 0);
    camera.target += const Vec3(1, 0, 0);
    frame(n);
  }
  frame(6);
  frame(7);
  controls.dispose();
}
