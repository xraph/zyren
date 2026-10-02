import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

/// End-to-end readback timings include Dart, worker, GPU wait and pixel copy.
Future<void> main() async {
  final results = <Map<String, Object?>>[];
  for (final count in [1000, 10000]) {
    final backend = await NativeBackend.create();
    try {
      final scene = Scene()..background = const Color3(0, 0, 0);
      final mesh = scene.add(
        InstancedMesh(
          BoxGeometry(width: .01, height: .01, depth: .01),
          UnlitMaterial(),
          count: count,
        ),
      );
      mesh.setTransforms(
        0,
        List.generate(
          count,
          (i) => Mat4.compose(
            Vec3((i % 100) * .02 - 1, (i ~/ 100) * .02 - 1, 0),
            Quat.identity,
            Vec3.one,
          ),
        ),
      );
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
      Future<FrameOutput> draw() => backend.render(
        FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: PhysicalSize(128, 128),
        ),
      );
      final initial = await draw();
      final resident = (await backend.resourceStats()).residentBytes;
      final groups = <String, Object>{};
      for (final change in ['camera', 'oneInstance', 'oneColor']) {
        final times = <int>[];
        for (var i = 0; i < 30; i++) {
          if (change == 'camera') {
            camera.position = Vec3(i * .001, 0, 4);
          } else if (change == 'oneColor') {
            mesh.setColor(0, Color3(i / 30, .4, .8));
          } else {
            mesh.setTransform(
              0,
              Mat4.compose(Vec3(-1, i * .01, 0), Quat.identity, Vec3.one),
            );
          }
          final timer = Stopwatch()..start();
          final frame = await draw();
          timer.stop();
          if (frame.stats.drawCalls != 1 ||
              frame.stats.uploadedBytes != (change == 'camera' ? 0 : 128)) {
            throw StateError(
              'Instancing draw/upload invariant failed: ${frame.stats.drawCalls} draws, ${frame.stats.uploadedBytes} bytes.',
            );
          }
          if (i >= 10) times.add(timer.elapsedMicroseconds);
        }
        times.sort();
        groups[change] = {
          'p50ReadbackFrameMs': times[times.length ~/ 2] / 1000,
          'p95ReadbackFrameMs': times[(times.length * .95).ceil() - 1] / 1000,
          'uploadedBytesPerFrame': change == 'camera' ? 0 : 128,
        };
      }
      if ((await backend.resourceStats()).residentBytes != resident) {
        throw StateError('Instance residency grew during exclusive updates.');
      }
      results.add({
        'instances': count,
        'drawCalls': initial.stats.drawCalls,
        'triangles': initial.stats.triangles,
        'initialUploadedBytes': initial.stats.uploadedBytes,
        'residentBytes': resident,
        'samplesPerCase': 20,
        'cases': groups,
      });
    } finally {
      await backend.close();
    }
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'platform': Platform.operatingSystem,
      'timing':
          'End-to-end explicit 128x128 readback, not GPU timestamps or presentation FPS.',
      'results': results,
    }),
  );
}
