import 'dart:convert';
import 'dart:io';
import 'package:shader_lab/shader_lab.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

Future<void> main() async {
  final backend = await NativeBackend.create();
  final fixture = RendererFixture();
  final engine = await SceneEngine.create(
    scene: fixture.scene,
    camera: fixture.camera,
    backendFactory: () async => backend,
    plugins: [
      RendererProfilePlugin(),
      fixture.environment(),
      ShaderLabPlugin(),
    ],
  );
  final profiles = <Map<String, Object>>[];
  try {
    for (final full in [false, true]) {
      fixture.scene.renderSettings = RenderSettings(
        toneMapping: ToneMapping.aces,
        sampleCount: full ? 4 : 1,
        spatialAntialiasing: full
            ? SpatialAntialiasing.fxaa
            : SpatialAntialiasing.none,
        bloom: full ? BloomSettings(intensity: .12) : null,
      );
      final samples = <int>[];
      for (var i = 0; i < 12; i++) {
        final timer = Stopwatch()..start();
        final frame = await engine.render(
          elapsed: Duration(milliseconds: i * 16),
          width: 512,
          height: 384,
        );
        if (i >= 4) samples.add(timer.elapsedMicroseconds);
        if (full && i == 11) {
          final path = Platform.environment['RENDERER_RGBA'];
          if (path != null) File(path).writeAsBytesSync(frame.pixels);
        }
      }
      final stats = await backend.graphStats();
      profiles.add({
        'profile': full ? 'MSAA4 + FXAA + bloom' : 'HDR single sample',
        'endToEndReadbackMicros': samples,
        'targetBytes': stats.targetBytes,
        'instanceBytes': stats.instanceBytes,
        'instanceDrawCalls': stats.instanceDrawCalls,
        'shadowBytes': stats.shadowBytes,
        'shadowPasses': stats.shadowPasses,
      });
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'backend': backend.capabilities.backend,
        'adapter': backend.capabilities.adapterName,
        'host': Platform.operatingSystemVersion,
        'release': const bool.fromEnvironment('dart.vm.product'),
        'size': [512, 384],
        'profiles': profiles,
      }),
    );
  } finally {
    await engine.dispose();
  }
}
