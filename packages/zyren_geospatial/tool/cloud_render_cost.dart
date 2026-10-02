import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

Future<void> main() async {
  final backend = await NativeBackend.create();
  final date = DateTime.utc(2026, 3, 20, 12);
  final sun = CelestialDirections.at(date).sunECEF;
  final clouds = CloudPlugin(
    quality: CloudQualityPreset.high,
    maxResolution: 640,
    shadowMapSize: 128,
  );
  final engine = await SceneEngine.create(
    scene: Scene()..renderSettings = RenderSettings(hdr: true),
    camera: PerspectiveCamera(
      position: sun * 6360100,
      target: sun * 6363000,
      up: const Vec3(0, 0, 1),
      near: 1,
      far: 1e7,
    ),
    backendFactory: () async => backend.createView(),
    plugins: [
      AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 32,
      ),
      clouds,
    ],
  );
  try {
    for (final shadows in [true, false]) {
      await clouds.controller.setQualitySettings(
        CloudQualitySettings(
          preset: CloudQualityPreset.high,
          maxResolution: 640,
          shadowMapSize: 128,
          shadowsEnabled: shadows,
        ),
      );
      for (var i = 0; i < 20; i++) {
        await engine.render(elapsed: Duration.zero, width: 1280, height: 720);
      }
      final times = <double>[];
      for (var i = 0; i < 48; i++) {
        final watch = Stopwatch()..start();
        await engine.render(elapsed: Duration.zero, width: 1280, height: 720);
        times.add(watch.elapsedMicroseconds / 1000);
      }
      times.sort();
      print(
        jsonEncode({
          'shadows': shadows,
          'samples': times.length,
          'medianMs': times[times.length ~/ 2],
          'p95Ms': times[(times.length * .95).floor()],
          'residentBytes': (await backend.resourceStats()).residentBytes,
          'viewport': [1280, 720],
          'cloudSize': [clouds.controller.width, clouds.controller.height],
          'includesReadback': true,
        }),
      );
    }
  } finally {
    await engine.dispose();
    await backend.close();
  }
}
