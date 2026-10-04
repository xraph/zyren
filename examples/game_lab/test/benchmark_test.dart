import 'package:test/test.dart';
import 'package:zyren_game_lab/benchmark.dart';

Map<String, Object?> finish(GameBenchmarkRecorder recorder) => recorder.finish(
  durationSeconds: 600,
  identity: {
    'device': 'unit-fixture',
    'physicalDevice': false,
    'buildMode': 'debug',
  },
  cleanupVerified: false,
  loadVerified: false,
  nativePresentation: false,
  actorLoadVerified: false,
  visualInputsVerified: false,
);

void main() {
  test('clock telemetry retains lateness, backlog and dropped time', () {
    final recorder = GameBenchmarkRecorder(
      gameBenchmarkProfiles['reference-guard']!,
    );
    recorder.gameCpu(1000);
    recorder.clockWake(
      latenessMicros: 800,
      pendingSteps: 2,
      advanced: true,
      droppedSeconds: .04,
    );
    recorder.clockWake(
      latenessMicros: 200,
      pendingSteps: 0,
      advanced: false,
      droppedSeconds: 0,
    );
    final receipt = finish(recorder);
    expect((receipt['clockWakeLatenessMicros'] as Map)['raw'], [800, 200]);
    expect((receipt['clockPendingSteps'] as Map)['raw'], [2, 0]);
    expect(receipt['clockAdvancedSteps'], 1);
    expect(receipt['clockDroppedSeconds'], .04);
    expect(receipt['diagnostics'], contains('dropped simulation time'));
    expect(
      receipt['diagnostics'],
      isNot(contains('realtime clock step coverage')),
    );
  });
  test('native frame workload keeps dimensions and unavailable GPU time', () {
    final r = GameBenchmarkRecorder(gameBenchmarkProfiles['reference-guard']!);
    void frame(int width, {int? gpuMicros}) => r.presentation(
      intervalMicros: 16666,
      readback: 0,
      width: width,
      height: 2061,
      cpuBuildMicros: 300,
      cpuSubmitMicros: 200,
      gpuMicros: gpuMicros,
    );
    expect(() => frame(0), throwsArgumentError);
    expect(() => frame(960, gpuMicros: -1), throwsArgumentError);
    frame(960);
    frame(960);
    frame(480);
    final receipt = finish(r);
    expect(receipt['frames'], 3);
    expect(receipt['nativeOutputSizes'], [
      {'width': 960, 'height': 2061, 'frames': 2},
      {'width': 480, 'height': 2061, 'frames': 1},
    ]);
    expect((receipt['nativeRenderBuildMicros'] as Map)['count'], 3);
    expect((receipt['nativeRenderSubmitMicros'] as Map)['p95'], 200);
    expect(receipt['nativeRenderGpuMicros'], isNull);
    expect(receipt['diagnostics'], contains('stable native output size'));
    final withGpu = GameBenchmarkRecorder(
      gameBenchmarkProfiles['reference-guard']!,
    );
    withGpu.presentation(
      intervalMicros: null,
      readback: 0,
      width: 960,
      height: 2061,
      cpuBuildMicros: 300,
      cpuSubmitMicros: 200,
      gpuMicros: 1000,
    );
    expect((finish(withGpu)['nativeRenderGpuMicros'] as Map)['raw'], [1000]);
  });
  test('one successful decision cannot qualify a sustained policy load', () {
    final r = GameBenchmarkRecorder(gameBenchmarkProfiles['reference-guard']!);
    for (var i = 0; i < 36000; i++) {
      r.fullFrame(1000);
      r.presentation(
        intervalMicros: 1000,
        readback: 0,
        width: 960,
        height: 2061,
        cpuBuildMicros: 200,
        cpuSubmitMicros: 100,
      );
      r.flutterFrame(1000);
    }
    r.gameCpu(1000);
    r.inference(1000);
    r.expectDecision('one', 1);
    r.resolveDecision('one', currentTick: 1, accepted: true);
    final receipt = finish(r);
    expect(
      receipt['diagnostics'],
      containsAll([
        'sustained simulation count',
        'decision deadlines',
        'sustained inference count',
      ]),
    );
  });
  test('camera samples keep observed readback separate from presentation', () {
    final r = GameBenchmarkRecorder(gameBenchmarkProfiles['reference-guard']!);
    r.cameraReservation(64000);
    r.cameraCapture(
      captureMicros: 1200,
      preprocessingMicros: 50,
      readbackBytes: 28224,
      reservedBytes: 0,
    );
    expect(
      () => r.cameraCapture(
        captureMicros: 1,
        preprocessingMicros: 1,
        readbackBytes: 0,
        reservedBytes: 0,
      ),
      throwsStateError,
    );
    final receipt = finish(r);
    expect(receipt['cameraReadbackBytes'], 28224);
    expect(receipt['readbackBytes'], 0);
    expect(receipt['sensorBytes'], 64000);
    expect((receipt['cameraCaptureMicros'] as Map)['p95'], 1200);
    expect((receipt['cameraPreprocessingMicros'] as Map)['count'], 1);
  });
  test('missing samples and device proof cannot qualify an empty run', () {
    final receipt = finish(
      GameBenchmarkRecorder(gameBenchmarkProfiles['reference-guard']!),
    );
    expect(receipt['status'], 'failed');
    expect(
      receipt['diagnostics'],
      containsAll([
        'physical device',
        'declared actor and policy load',
        'native presentation',
        'native cleanup',
        'decision deadlines',
        'full native frame p95',
      ]),
    );
    expect((receipt['fullFrameMicros'] as Map)['p95'], isNull);
    expect(receipt['nativeArenaBytes'], isNull);
    expect(receipt['physicalGpuBytes'], isNull);
    expect(receipt['thermalState'], isNull);
  });
  test(
    'every admitted decision settles once including late and cancelled work',
    () {
      final r = GameBenchmarkRecorder(
        gameBenchmarkProfiles['reference-guard']!,
      );
      r.expectDecision('first', 2);
      r.expectDecision('late', 2);
      r.expectDecision('cancelled', 3);
      expect(() => r.expectDecision('first', 2), throwsStateError);
      expect(
        () => r.resolveDecision('first', currentTick: 1, accepted: true),
        throwsStateError,
      );
      expect(r.applicationTick('first'), 2);
      r.resolveDecision('first', currentTick: 2, accepted: true);
      r.resolveDecision('late', currentTick: 3, accepted: true);
      expect(
        () => r.resolveDecision('first', currentTick: 2, accepted: true),
        throwsStateError,
      );
      final receipt = finish(r);
      expect(receipt['dueDecisions'], 3);
      expect(receipt['completedDecisions'], 1);
      expect(receipt['missedDecisions'], 2);
      expect(receipt['staleActionsApplied'], 1);
      expect(receipt['diagnostics'], contains('invalid or stale actions'));
      expect(
        () => r.presentation(
          intervalMicros: 10,
          readback: 0,
          width: 960,
          height: 2061,
          cpuBuildMicros: 200,
          cpuSubmitMicros: 100,
        ),
        throwsStateError,
      );
    },
  );
  test('raw bounded samples preserve a sustained tail and peak accounting', () {
    final r = GameBenchmarkRecorder(
      gameBenchmarkProfiles['reference-vehicle']!,
      maxSamples: 100,
    );
    for (var i = 0; i < 100; i++) {
      r.fullFrame(i < 94 ? 1000 : 30000);
    }
    expect(() => r.fullFrame(1), throwsStateError);
    r.memory(rss: 100, weights: 50, tensors: 12, recurrent: 8);
    r.memory(rss: 90, weights: 50, tensors: 18, recurrent: 4);
    final receipt = finish(r);
    expect((receipt['fullFrameMicros'] as Map)['p95'], 30000);
    expect((receipt['fullFrameMicros'] as Map)['raw'], hasLength(100));
    expect(receipt['peakRssBytes'], 100);
    expect(receipt['peakTensorBytes'], 18);
    expect(receipt['peakRecurrentBytes'], 8);
  });
  test('planned profiles keep evaluated reference rates separate', () {
    for (final profile in gameBenchmarkProfiles.values) {
      profile.validate();
    }
    expect(gameBenchmarkProfiles['desktop-structured']!.actors, 144);
    expect(gameBenchmarkProfiles['desktop-structured']!.fixedHz, 60);
    expect(gameBenchmarkProfiles['reference-guard']!.fixedHz, 50);
    expect(gameBenchmarkProfiles['reference-guard']!.guardHz, 50);
    expect(
      () => const GameBenchmarkProfile(
        id: 'invalid',
        fixedHz: 50,
        guards: 1,
        vehicles: 0,
        guardHz: 30,
        vehicleHz: 0,
      ).validate(),
      throwsArgumentError,
    );
  });
  test('sensor reasons and system timings stay bounded and attributable', () {
    final r = GameBenchmarkRecorder(
      gameBenchmarkProfiles['reference-guard']!,
      maxSamples: 2,
    );
    r.systemCpu('physics', 200);
    r.systemCpu('physics', 300);
    expect(() => r.systemCpu('physics', 1), throwsStateError);
    r.observation('body', 'unknown', 'speed-out-of-range');
    r.observation('body', 'unknown', 'speed-out-of-range');
    r.inferenceOutcome('ready');
    final receipt = finish(r);
    expect(((receipt['systemCpuMicros'] as Map)['physics'] as Map)['p95'], 300);
    expect(receipt['sensorStates'], {'body/unknown/speed-out-of-range': 2});
    expect(receipt['inferenceOutcomes'], {'ready': 1});
    expect(() => r.observation('body', 'known', null), throwsStateError);
  });
}
