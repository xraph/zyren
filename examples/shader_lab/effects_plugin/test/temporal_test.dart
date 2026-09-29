import 'dart:io';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren/zyren.dart';
import 'effects_test.dart' show UnsupportedBackend;
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'package:test/test.dart';
import 'support/temporal_checks.dart';

void main() {
  test('temporal retention must converge and stay finite', () {
    for (final value in [-.1, 1.0, double.nan, double.infinity]) {
      expect(() => TemporalBlendPlugin(retention: value), throwsArgumentError);
    }
    final plugin = TemporalBlendPlugin(retention: 0);
    expect(() => plugin.retention = 1, throwsArgumentError);
  });
  test(
    'temporal effects reject missing capabilities or bypass explicitly',
    () async {
      final rejected = UnsupportedBackend();
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => rejected,
          plugins: [TemporalBlendPlugin(enabled: true)],
        ),
        throwsA(isA<SceneException>()),
      );
      expect(rejected.closed, isTrue);
      final bypassed = UnsupportedBackend();
      final plugin = TemporalBlendPlugin(
        enabled: true,
        unsupported: UnsupportedEffects.bypass,
      );
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => bypassed,
        plugins: [plugin],
      );
      try {
        plugin.reset();
        await engine.renderFrame(elapsed: Duration.zero, width: 1, height: 1);
        expect(plugin.historyFrames, 0);
      } finally {
        await engine.dispose();
      }
    },
  );
  test('native frame history, invalidation and independent views', () async {
    final backend = await NativeBackend.create();
    try {
      await verifyTemporalHistory(backend);
      await verifyComputeHistory(backend);
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
