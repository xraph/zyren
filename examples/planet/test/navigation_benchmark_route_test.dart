import 'package:flutter_test/flutter_test.dart';
import 'package:planet/navigation_benchmark_route.dart';
import 'package:zyren/zyren.dart';
import '../../../packages/flutter_zyren/test/support/backend_fake.dart';

final class _CameraUpdate extends ScenePlugin {
  @override
  String get id => 'camera-update';
  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    context.camera.position = const Vec3(3, 2, 5);
    (context.camera as PerspectiveCamera).near = .2;
  }
}

void main() {
  test(
    'capture matches final camera source and removal restores plugins',
    () async {
      final capture = NavigationMotionCapture();
      final cameraUpdate = _CameraUpdate();
      final backend = FakeBackend();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [capture, cameraUpdate],
      );
      final clock = Stopwatch()..start();
      capture.reset(clock);
      capture.appliedAtUs = 5000000;
      capture.wave = .8;
      final result = await engine.renderFrame(
        elapsed: Duration.zero,
        width: 8,
        height: 8,
      );
      capture.appliedAtUs = 7000000;
      final source = result.stats.source!;
      final motion = capture.frames.take(
        result.stats.frameId,
        source.cameraRevision,
        source.cameraRuntimeId,
      );
      expect(motion?['commandAppliedAtUs'], 5000000);
      expect(motion?['cameraPosition'], [3.0, 2.0, 5.0]);
      capture.frames.record(99, 1, 2, {});
      await engine.updatePlugins([cameraUpdate]);
      expect(engine.pluginIds, ['camera-update']);
      expect(capture.clock, isNull);
      expect(clock.isRunning, isFalse);
      expect(capture.frames.take(99, 1, 2), isNull);
      await engine.dispose();
      expect(backend.closeCount, 1);
    },
  );

  test(
    'delayed receipts retain their own command and reject mismatched source',
    () {
      final frames = NavigationMotionFrames();
      frames.record(1, 10, 20, {'commandAppliedAtUs': 5000000});
      frames.record(2, 11, 20, {'commandAppliedAtUs': 7000000});
      expect(frames.take(1, 10, 20)?['commandAppliedAtUs'], 5000000);
      expect(frames.take(2, 10, 20), isNull);
      frames.record(3, 12, 20, {'commandAppliedAtUs': 8000000});
      expect(frames.take(3, null, 20), isNull);
    },
  );

  test('device defaults adapt and named presets stay fixed', () {
    for (final variant in ['auto', 'shadowsOff', 'sparse']) {
      expect(navigationAdaptiveClouds(variant), isTrue);
    }
    for (final variant in ['low', 'medium', 'high']) {
      expect(navigationAdaptiveClouds(variant), isFalse);
    }
    expect(() => navigationAdaptiveClouds('unknown'), throwsArgumentError);
  });
  List<Map<String, Object?>> trajectory() => [
    for (var us = 500000; us <= navigationPhaseDurationUs; us += 500000)
      {
        'phaseElapsedUs': us,
        'commandAppliedAtUs': us - 1000,
        'commandedWave': navigationWave('reversal', us - 1000),
        'cameraPosition': [
          navigationWave('reversal', us - 1000) * 100,
          0.0,
          0.0,
        ],
      },
  ];
  String? failure(
    List<Map<String, Object?>> frames, {
    int? reversal = 6500000,
  }) => navigationPhaseFailure(
    'reversal',
    frames,
    elapsedUs: navigationPhaseDurationUs,
    appliedReversalUs: reversal,
  );
  test('reversal requires live receipts through the exact phase boundary', () {
    expect(failure(trajectory()), isNull);
    expect(failure(trajectory().take(2).toList()), isNotNull);
    expect(failure(trajectory()..removeLast()), isNotNull);
    expect(failure(trajectory()..removeRange(4, 7)), isNotNull);
    expect(failure(trajectory()..removeRange(0, 2)), isNotNull);
    expect(
      navigationPhaseFailure(
        'stationary',
        trajectory(),
        elapsedUs: navigationPhaseDurationUs + navigationMaxReceiptGapUs,
      ),
      isNull,
    );
    expect(
      navigationPhaseFailure(
        'stationary',
        trajectory(),
        elapsedUs: navigationPhaseDurationUs + navigationMaxReceiptGapUs + 1,
      ),
      isNotNull,
    );
  });
  test('missing or unpresented reversal cannot qualify', () {
    expect(failure(trajectory(), reversal: null), isNotNull);
    final noPost = trajectory()
        .where((f) => (f['commandAppliedAtUs'] as int) < 6500000)
        .toList();
    expect(failure(noPost), isNotNull);
    final delayed = trajectory();
    for (final frame in delayed) {
      if ((frame['phaseElapsedUs'] as int) >= 6500000) {
        frame['commandAppliedAtUs'] = 5500000;
        frame['commandedWave'] = navigationWave('reversal', 5500000);
        frame['cameraPosition'] = [90.0, 0.0, 0.0];
      }
    }
    expect(failure(delayed), isNotNull);
  });
  test('unknown or unchanged accepted camera does not prove reversal', () {
    final unknown = trajectory();
    for (final frame in unknown) {
      frame.remove('cameraPosition');
    }
    expect(failure(unknown), isNotNull);
    final still = trajectory();
    for (final frame in still) {
      frame['cameraPosition'] = [1.0, 2.0, 3.0];
    }
    expect(failure(still), isNotNull);
    final continuing = trajectory();
    for (var i = 0; i < continuing.length; i++) {
      continuing[i]['cameraPosition'] = [i.toDouble(), 0.0, 0.0];
    }
    expect(failure(continuing), isNotNull);
  });
  test(
    'fifth phase reverses velocity sharply at six seconds within bounds',
    () {
      expect(navigationPhases.length, 5);
      expect(navigationPhases.last, 'reversal');
      expect(navigationWave('reversal', 0), 0);
      expect(navigationWave('reversal', navigationReversalUs), 1);
      expect(navigationWave('reversal', navigationPhaseDurationUs), 0);
      final before = navigationWave('reversal', navigationReversalUs - 1000);
      final after = navigationWave('reversal', navigationReversalUs + 1000);
      expect(before, closeTo(after, 1e-12));
      expect(before, lessThan(1));
      for (var us = -1000000; us <= 13000000; us += 100000) {
        expect(navigationWave('reversal', us), inInclusiveRange(0, 1));
      }
    },
  );
}
