import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

Future<void> main() async {
  final backend = await NativeBackend.create();
  final scene = Scene();
  final mesh = scene.add(
    InstancedMesh(PlaneGeometry(), UnlitMaterial(), count: 10000),
  );
  for (var i = 0; i < mesh.count; i++) {
    mesh.setTransform(
      i,
      Mat4.compose(
        Vec3((i % 100 - 49.5) * .025, (i ~/ 100 - 49.5) * .025, 0),
        Quat.identity,
        const Vec3(.015, .015, .015),
      ),
    );
  }
  final camera = PerspectiveCamera();
  final times = <int>[], captures = <int>[];
  try {
    for (var i = 0; i < 12; i++) {
      final timer = Stopwatch()..start();
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(128, 128),
      );
      final capture = timer.elapsedMicroseconds;
      await backend.render(frame);
      if (i >= 4) {
        captures.add(capture);
        times.add(timer.elapsedMicroseconds);
      }
    }
    final before = await backend.graphStats();
    mesh.setTransform(
      0,
      Mat4.compose(
        const Vec3(-1, -1, .1),
        Quat.identity,
        const Vec3(.015, .015, .015),
      ),
    );
    await backend.render(
      FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(128, 128),
      ),
    );
    final after = await backend.graphStats();
    await backend.render(
      FrameSubmission.capture(
        scene: Scene(),
        camera: camera,
        size: PhysicalSize(128, 128),
      ),
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'backend': backend.capabilities.name,
        'host': Platform.operatingSystemVersion,
        'release': const bool.fromEnvironment('dart.vm.product'),
        'instances': mesh.count,
        'size': [128, 128],
        'captureMicros': captures,
        'endToEndReadbackMicros': times,
        'instanceBytes': before.instanceBytes,
        'instanceDrawCalls': before.instanceDrawCalls,
        'singleEditUploadedBytes':
            after.instanceUploadedBytes - before.instanceUploadedBytes,
        'remainingInstanceBytes': (await backend.graphStats()).instanceBytes,
      }),
    );
  } finally {
    await backend.close();
  }
}
