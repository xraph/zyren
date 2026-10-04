import 'dart:math' as math;

/// A measured load. Changing cadence needs a separately evaluated policy.
final class GameBenchmarkProfile {
  final String id;
  final int fixedHz, guards, vehicles, cameras, guardHz, vehicleHz, cameraHz;
  final int seconds, repetitions, width, height;
  final double frameBudgetMs, schedulingBudgetMs, minimumReadyFraction;
  const GameBenchmarkProfile({
    required this.id,
    required this.fixedHz,
    required this.guards,
    required this.vehicles,
    required this.guardHz,
    required this.vehicleHz,
    this.cameras = 0,
    this.cameraHz = 0,
    this.width = 84,
    this.height = 84,
    this.seconds = 600,
    this.repetitions = 3,
    this.frameBudgetMs = 16.7,
    this.schedulingBudgetMs = 2,
    this.minimumReadyFraction = .99,
  });
  int get actors => guards + vehicles;
  Map<String, Object?> toJson() => {
    'id': id,
    'fixedHz': fixedHz,
    'guards': guards,
    'vehicles': vehicles,
    'guardHz': guardHz,
    'vehicleHz': vehicleHz,
    'cameras': cameras,
    'cameraHz': cameraHz,
    'width': width,
    'height': height,
    'seconds': seconds,
    'repetitions': repetitions,
    'frameBudgetMs': frameBudgetMs,
    'schedulingBudgetMs': schedulingBudgetMs,
    'minimumReadyFraction': minimumReadyFraction,
  };
  void validate() {
    if (id.isEmpty ||
        id.length > 80 ||
        fixedHz < 10 ||
        fixedHz > 240 ||
        guards < 0 ||
        vehicles < 0 ||
        actors < 1 ||
        actors > 256 ||
        cameras < 0 ||
        cameras > actors ||
        seconds < 600 ||
        seconds > 3600 ||
        repetitions < 3 ||
        repetitions > 10 ||
        width != 84 ||
        height != 84 ||
        !frameBudgetMs.isFinite ||
        frameBudgetMs <= 0 ||
        !schedulingBudgetMs.isFinite ||
        schedulingBudgetMs <= 0 ||
        !minimumReadyFraction.isFinite ||
        minimumReadyFraction < .99 ||
        minimumReadyFraction > 1) {
      throw ArgumentError('Invalid qualification profile.');
    }
    for (final pair in [
      (guards, guardHz),
      (vehicles, vehicleHz),
      (cameras, cameraHz),
    ]) {
      if (pair.$1 > 0 &&
          (pair.$2 < 1 || pair.$2 > fixedHz || fixedHz % pair.$2 != 0)) {
        throw ArgumentError(
          'Decision rates must divide the fixed simulation rate.',
        );
      }
    }
  }
}

const gameBenchmarkProfiles = <String, GameBenchmarkProfile>{
  'mobile-structured': GameBenchmarkProfile(
    id: 'mobile-structured',
    fixedHz: 60,
    guards: 32,
    vehicles: 4,
    guardHz: 10,
    vehicleHz: 20,
  ),
  'desktop-structured': GameBenchmarkProfile(
    id: 'desktop-structured',
    fixedHz: 60,
    guards: 128,
    vehicles: 16,
    guardHz: 10,
    vehicleHz: 20,
  ),
  'mobile-visual': GameBenchmarkProfile(
    id: 'mobile-visual',
    fixedHz: 60,
    guards: 4,
    vehicles: 0,
    guardHz: 10,
    vehicleHz: 0,
    cameras: 4,
    cameraHz: 10,
  ),
  'desktop-visual': GameBenchmarkProfile(
    id: 'desktop-visual',
    fixedHz: 60,
    guards: 16,
    vehicles: 0,
    guardHz: 10,
    vehicleHz: 0,
    cameras: 16,
    cameraHz: 10,
  ),
  // Reference policies have their own evaluation rate and capacity identity.
  'reference-guard': GameBenchmarkProfile(
    id: 'reference-guard',
    fixedHz: 50,
    guards: 1,
    vehicles: 0,
    guardHz: 50,
    vehicleHz: 0,
  ),
  'reference-vehicle': GameBenchmarkProfile(
    id: 'reference-vehicle',
    fixedHz: 50,
    guards: 0,
    vehicles: 1,
    guardHz: 0,
    vehicleHz: 50,
  ),
};

/// Bounded raw measurements. The host supplies observed events, never estimates
/// native allocations or substitutes inferred temperatures for missing sensors.
final class GameBenchmarkRecorder {
  final GameBenchmarkProfile profile;
  final int maxSamples;
  final _presentation = <int>[], _flutter = <int>[], _gameCpu = <int>[];
  final _fullFrame = <int>[];
  final _renderBuild = <int>[], _renderSubmit = <int>[], _renderGpu = <int>[];
  final _nativePrepare = <int>[],
      _nativeEncode = <int>[],
      _nativeWait = <int>[];
  final _renderSizes = <(int, int), int>{};
  final _inference = <int>[];
  final _clockLateness = <int>[], _clockPending = <int>[];
  int clockAdvancedSteps = 0;
  double clockDroppedSeconds = 0;
  final _capture = <int>[], _preprocessing = <int>[];
  final _systems = <String, List<int>>{};
  final _observations = <String, int>{};
  final _outcomes = <String, int>{};
  final _expected = <String, int>{};
  final _lifecycles = <String>{};
  int due = 0, completed = 0, missed = 0, staleApplied = 0;
  int frames = 0, readbackBytes = 0, peakRssBytes = 0, invalidActions = 0;
  int modelBytes = 0, peakTensorBytes = 0, peakRecurrentBytes = 0;
  int rejectedActions = 0, fallbackTicks = 0, scriptedTicks = 0;
  int cameraReadbackBytes = 0;
  int? nativeArenaBytes, appSizeDeltaBytes, sensorBytes, physicalGpuBytes;
  Object? thermalState, powerWatts;
  bool _finished = false;
  GameBenchmarkRecorder(this.profile, {this.maxSamples = 1000000}) {
    profile.validate();
    if (maxSamples < 1 || maxSamples > 1000000) {
      throw ArgumentError('Sample limit exceeded.');
    }
  }
  void _open() {
    if (_finished) throw StateError('Benchmark receipt is finalized.');
  }

  void _sample(List<int> values, int value) {
    _open();
    if (value < 0 || values.length >= maxSamples) {
      throw StateError('Invalid or excessive measurement.');
    }
    values.add(value);
  }

  void presentation({
    required int? intervalMicros,
    required int readback,
    required int width,
    required int height,
    required int cpuBuildMicros,
    required int cpuSubmitMicros,
    int? gpuMicros,
    int? nativePrepareMicros,
    int? nativeEncodeMicros,
    int? nativeCompletionWaitMicros,
  }) {
    _open();
    if (readback < 0 ||
        width < 1 ||
        height < 1 ||
        width > 32768 ||
        height > 32768 ||
        cpuBuildMicros < 0 ||
        cpuSubmitMicros < 0 ||
        [
          gpuMicros,
          nativePrepareMicros,
          nativeEncodeMicros,
          nativeCompletionWaitMicros,
        ].any((v) => v != null && v < 0)) {
      throw ArgumentError('Invalid native frame measurement.');
    }
    final size = (width, height);
    if (!_renderSizes.containsKey(size) && _renderSizes.length >= 32) {
      throw StateError('Too many native output size changes.');
    }
    _sample(_renderBuild, cpuBuildMicros);
    _sample(_renderSubmit, cpuSubmitMicros);
    if (gpuMicros != null) _sample(_renderGpu, gpuMicros);
    if (nativePrepareMicros != null) {
      _sample(_nativePrepare, nativePrepareMicros);
    }
    if (nativeEncodeMicros != null) _sample(_nativeEncode, nativeEncodeMicros);
    if (nativeCompletionWaitMicros != null) {
      _sample(_nativeWait, nativeCompletionWaitMicros);
    }
    _renderSizes.update(size, (count) => count + 1, ifAbsent: () => 1);
    frames++;
    readbackBytes += readback;
    if (intervalMicros != null) _sample(_presentation, intervalMicros);
  }

  void flutterFrame(int totalMicros) => _sample(_flutter, totalMicros);
  void fullFrame(int micros) => _sample(_fullFrame, micros);
  void gameCpu(int micros) => _sample(_gameCpu, micros);
  void inference(int micros) => _sample(_inference, micros);
  void clockWake({
    required int latenessMicros,
    required int pendingSteps,
    required bool advanced,
    required double droppedSeconds,
  }) {
    if (!droppedSeconds.isFinite || droppedSeconds < 0 || pendingSteps > 64) {
      throw ArgumentError('Invalid realtime clock measurement.');
    }
    _sample(_clockLateness, latenessMicros);
    _sample(_clockPending, pendingSteps);
    if (advanced) clockAdvancedSteps++;
    clockDroppedSeconds += droppedSeconds;
  }

  void cameraCapture({
    required int captureMicros,
    required int preprocessingMicros,
    required int readbackBytes,
    required int reservedBytes,
  }) {
    if (readbackBytes <= 0 || reservedBytes < 0) {
      throw StateError('Camera capture requires observed native readback.');
    }
    _sample(_capture, captureMicros);
    _sample(_preprocessing, preprocessingMicros);
    cameraReadbackBytes += readbackBytes;
    cameraReservation(reservedBytes);
  }

  void cameraReservation(int bytes) {
    _open();
    if (bytes < 0) throw ArgumentError('Negative camera payload reservation.');
    sensorBytes = math.max(sensorBytes ?? 0, bytes);
  }

  void systemCpu(String id, int micros) {
    _boundedKey(_systems, id);
    _sample(_systems.putIfAbsent(id, () => []), micros);
  }

  void observation(String sensor, String state, String? reason) =>
      _count(_observations, '$sensor/$state/${reason ?? 'none'}');
  void inferenceOutcome(String outcome) => _count(_outcomes, outcome);

  void _boundedKey(Map<String, Object?> values, String key) {
    _open();
    if (key.isEmpty ||
        key.length > 256 ||
        !values.containsKey(key) && values.length >= 128) {
      throw StateError('Invalid or excessive measurement identity.');
    }
  }

  void _count(Map<String, int> values, String key) {
    _boundedKey(values, key);
    values.update(key, (count) => count + 1, ifAbsent: () => 1);
  }

  void expectDecision(String key, int applicationTick) {
    _open();
    if (applicationTick < 0 ||
        key.isEmpty ||
        key.length > 512 ||
        _expected.containsKey(key) ||
        _expected.length >= 16384) {
      throw StateError('Duplicate or excessive decision admission.');
    }
    _expected[key] = applicationTick;
  }

  void resolveDecision(
    String key, {
    required int currentTick,
    required bool accepted,
  }) {
    _open();
    final expected = _expected[key];
    if (expected == null || currentTick < expected) {
      throw StateError('Decision is missing or not due.');
    }
    _expected.remove(key);
    due++;
    if (accepted && currentTick == expected) {
      completed++;
    } else {
      missed++;
      if (accepted) staleApplied++;
    }
  }

  void cancelDecisions(Iterable<String> keys) {
    _open();
    for (final key in keys) {
      if (_expected.remove(key) != null) {
        due++;
        missed++;
      }
    }
  }

  Map<String, int> get pending => Map.unmodifiable(_expected);
  int? applicationTick(String key) => _expected[key];
  void lifecycle(String event) {
    _open();
    if (!{
      'camera-movement',
      'spawn',
      'despawn',
      'pause',
      'resume',
      'renderer-recreated',
    }.contains(event)) {
      throw ArgumentError('Unknown lifecycle operation.');
    }
    _lifecycles.add(event);
  }

  void memory({
    required int rss,
    required int weights,
    required int tensors,
    required int recurrent,
  }) {
    _open();
    if ([rss, weights, tensors, recurrent].any((n) => n < 0)) {
      throw ArgumentError('Invalid memory measurement.');
    }
    peakRssBytes = math.max(peakRssBytes, rss);
    modelBytes = math.max(modelBytes, weights);
    peakTensorBytes = math.max(peakTensorBytes, tensors);
    peakRecurrentBytes = math.max(peakRecurrentBytes, recurrent);
  }

  Map<String, Object?> finish({
    required double durationSeconds,
    required Map<String, Object?> identity,
    required bool cleanupVerified,
    required bool loadVerified,
    required bool nativePresentation,
    required bool actorLoadVerified,
    required bool visualInputsVerified,
  }) {
    _open();
    cancelDecisions(_expected.keys.toList());
    _finished = true;
    final errors = <String>[];
    void require(bool condition, String message) {
      if (!condition) errors.add(message);
    }

    require(
      durationSeconds.isFinite && durationSeconds >= profile.seconds,
      'duration',
    );
    require(
      identity['buildMode'] == 'profile' || identity['buildMode'] == 'release',
      'build mode',
    );
    require(identity['physicalDevice'] == true, 'physical device');
    for (final key in [
      'device',
      'os',
      'renderer',
      'provider',
      'buildHash',
      'gameHash',
    ]) {
      require(
        identity[key] is String && (identity[key] as String).isNotEmpty,
        '$key identity',
      );
    }
    final pins = identity['modelHashes'];
    require(
      pins is List &&
          pins.isNotEmpty &&
          pins.every(
            (p) => p is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(p),
          ),
      'model identities',
    );
    require(
      loadVerified && actorLoadVerified,
      'declared actor and policy load',
    );
    require(nativePresentation, 'native presentation');
    require(_renderSizes.length == 1, 'stable native output size');
    require(
      profile.cameras == 0 || visualInputsVerified,
      'native visual inputs',
    );
    require(cleanupVerified, 'native cleanup');
    require(
      frames >= durationSeconds * 60 * .95,
      'sustained presentation count',
    );
    require(
      _presentation.isNotEmpty &&
          percentile(_presentation, .95)! <= profile.frameBudgetMs * 1000,
      'presentation p95',
    );
    require(
      _flutter.isNotEmpty &&
          percentile(_flutter, .95)! <= profile.frameBudgetMs * 1000,
      'Flutter frame p95',
    );
    require(
      _fullFrame.isNotEmpty &&
          percentile(_fullFrame, .95)! <= profile.frameBudgetMs * 1000,
      'full native frame p95',
    );
    require(
      _gameCpu.isNotEmpty &&
          percentile(_gameCpu, .95)! <= profile.schedulingBudgetMs * 1000,
      'game and perception CPU p95',
    );
    require(
      _gameCpu.length >= durationSeconds * profile.fixedHz * .95,
      'sustained simulation count',
    );
    final decisionRate =
        profile.guards * profile.guardHz + profile.vehicles * profile.vehicleHz;
    require(
      due > 0 &&
          due >= durationSeconds * decisionRate * .95 &&
          due == completed + missed &&
          completed / due >= profile.minimumReadyFraction,
      'decision deadlines',
    );
    final inferenceRate = math.max(
      profile.guards > 0 ? profile.guardHz : 0,
      profile.vehicles > 0 ? profile.vehicleHz : 0,
    );
    require(
      _inference.length >= durationSeconds * inferenceRate * .95,
      'sustained inference count',
    );
    require(
      staleApplied == 0 && invalidActions == 0,
      'invalid or stale actions',
    );
    require(_lifecycles.length == 6, 'lifecycle coverage');
    require(modelBytes > 0 && peakRssBytes > 0, 'memory measurements');
    if (_clockLateness.isNotEmpty) {
      require(clockDroppedSeconds == 0, 'dropped simulation time');
      require(
        clockAdvancedSteps == _gameCpu.length,
        'realtime clock step coverage',
      );
    }
    return {
      'schemaVersion': 1,
      'status': errors.isEmpty ? 'passed' : 'failed',
      'profile': profile.toJson(),
      'identity': identity,
      'diagnostics': errors,
      'durationSeconds': durationSeconds,
      'frames': frames,
      'frameMeasurement':
          'first native scene preparation hook through presenter acceptance, plus Flutter totalSpan; not physical scanout latency',
      'fullFrameMicros': distribution(_fullFrame),
      'nativeRenderBuildMicros': distribution(_renderBuild),
      'nativeRenderSubmitMicros': distribution(_renderSubmit),
      'nativeRenderGpuMicros': _renderGpu.isEmpty
          ? null
          : distribution(_renderGpu),
      'nativePrepareMicros': _nativePrepare.isEmpty
          ? null
          : distribution(_nativePrepare),
      'nativeEncodeMicros': _nativeEncode.isEmpty
          ? null
          : distribution(_nativeEncode),
      'nativeCompletionWaitMicros': _nativeWait.isEmpty
          ? null
          : distribution(_nativeWait),
      'nativeProfileMeasurement':
          'native CPU preparation, encoding and completion wait; wait can overlap GPU execution, so these intervals are not additive',
      'nativeOutputSizes': [
        for (final entry in _renderSizes.entries)
          {
            'width': entry.key.$1,
            'height': entry.key.$2,
            'frames': entry.value,
          },
      ],
      'presentationMicros': distribution(_presentation),
      'flutterFrameMicros': distribution(_flutter),
      'gamePerceptionCpuMicros': distribution(_gameCpu),
      'clockWakeLatenessMicros': _clockLateness.isEmpty
          ? null
          : distribution(_clockLateness),
      'clockPendingSteps': _clockPending.isEmpty
          ? null
          : distribution(_clockPending),
      'clockAdvancedSteps': _clockLateness.isEmpty ? null : clockAdvancedSteps,
      'clockDroppedSeconds': _clockLateness.isEmpty
          ? null
          : clockDroppedSeconds,
      'inferenceRoundTripMicros': distribution(_inference),
      'cameraCaptureMicros': distribution(_capture),
      'cameraPreprocessingMicros': distribution(_preprocessing),
      'cameraReadbackBytes': cameraReadbackBytes,
      'systemCpuMicros': {
        for (final entry in _systems.entries)
          entry.key: distribution(entry.value),
      },
      'sensorStates': Map<String, int>.unmodifiable(_observations),
      'inferenceOutcomes': Map<String, int>.unmodifiable(_outcomes),
      'dueDecisions': due,
      'completedDecisions': completed,
      'missedDecisions': missed,
      'staleActionsApplied': staleApplied,
      'invalidActions': invalidActions,
      'rejectedActions': rejectedActions,
      'fallbackTicks': fallbackTicks,
      'scriptedTicks': scriptedTicks,
      'lifecycle': _lifecycles.toList()..sort(),
      'loadVerified': loadVerified,
      'actorLoadVerified': actorLoadVerified,
      'nativePresentation': nativePresentation,
      'visualInputsVerified': visualInputsVerified,
      'cleanupVerified': cleanupVerified,
      'readbackBytes': readbackBytes,
      'modelBytes': modelBytes,
      'peakRssBytes': peakRssBytes,
      'peakTensorBytes': peakTensorBytes,
      'peakRecurrentBytes': peakRecurrentBytes,
      'nativeArenaBytes': nativeArenaBytes,
      'sensorBytes': sensorBytes,
      'appSizeDeltaBytes': appSizeDeltaBytes,
      'physicalGpuBytes': physicalGpuBytes,
      'thermalState': thermalState,
      'powerWatts': powerWatts,
    };
  }

  static double? percentile(List<int> values, double p) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    return sorted[(p * sorted.length).ceil().clamp(1, sorted.length) - 1]
        .toDouble();
  }

  static Map<String, Object?> distribution(List<int> values) => {
    'count': values.length,
    'p50': percentile(values, .5),
    'p95': percentile(values, .95),
    'p99': percentile(values, .99),
    'raw': List<int>.unmodifiable(values),
  };
}
