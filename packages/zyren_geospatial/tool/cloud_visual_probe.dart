import 'dart:io';
import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

Future<void> main(List<String> args) async {
  final output = Directory(args.isEmpty ? '/tmp/zyren-night-20261002' : args[0])
    ..createSync(recursive: true);
  final backend = await NativeBackend.create();
  final services = AssetServices(
    resolver: NativeSourceResolver(),
    imageDecoder: NativeImageDecoder(),
  );
  final date = DateTime.utc(2026, 3, 20, 12);
  final clouds = CloudPlugin(
    source: CloudTextureSource.upstream(services: services),
    animationEnabled: false,
    quality: CloudQualityPreset.high,
    maxResolution: 640,
    shadowsEnabled: false,
    appearance: CloudAppearance(hazeDensityScale: 0),
    temporal: CloudTemporalSettings(
      mode: args.length > 1 && args[1] == 'off'
          ? CloudTemporalMode.off
          : CloudTemporalMode.upscale,
    ),
  );
  final engine = await SceneEngine.create(
    scene: Scene()
      ..renderSettings = RenderSettings(
        hdr: true,
        exposure: 10,
        toneMapping: ToneMapping.agx,
      ),
    camera: PerspectiveCamera(
      position: const Vec3(7400000, 0, 1200000),
      target: const Vec3(6371000, 0, 0),
      up: const Vec3(0, 0, 1),
      near: 1,
      far: 1e9,
    ),
    backendFactory: () async => backend.createView(),
    plugins: [
      AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 16,
        appearance: AtmosphereAppearance(sky: false, haze: false),
      ),
      clouds,
    ],
  );
  try {
    final watch = Stopwatch()..start();
    for (var i = 0; i < 32; i++) {
      final frame = await engine.render(
        elapsed: Duration.zero,
        width: 1280,
        height: 720,
      );
      if (i == 15 || i == 31) {
        File('${output.path}/orbital-$i.rgba').writeAsBytesSync(frame.pixels);
      }
    }
    print(
      jsonEncode({
        'frames': 32,
        'elapsedMs': watch.elapsedMilliseconds,
        'cloudSize': [clouds.controller.width, clouds.controller.height],
        'registryPayloadBytes': (await backend.resourceStats()).residentBytes,
      }),
    );
  } finally {
    await engine.dispose();
    await backend.close();
  }
}
