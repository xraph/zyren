import 'package:zyren/zyren.dart';

/// Optional feedback from completed scene submissions. Shadow resource graphs
/// execute separately and are outside this measurement.
final class CloudSceneFrameBudget {
  final Duration target;
  final int pressureSamples, recoverySamples, cooldownSamples;
  CloudSceneFrameBudget({
    this.target = const Duration(microseconds: 16667),
    this.pressureSamples = 12,
    this.recoverySamples = 60,
    this.cooldownSamples = 30,
  }) {
    if (target <= Duration.zero ||
        pressureSamples < 1 ||
        recoverySamples < 1 ||
        cooldownSamples < 0) {
      throw ArgumentError('Invalid scene frame budget.');
    }
  }
}

/// Bounded sampling policy. Missing or partial measurements reset the evidence
/// streak and leave quality unchanged. Requested source presets stay separate.
final class CloudSceneFrameController {
  final CloudSceneFrameBudget budget;
  int _level = 0, _pressure = 0, _recovery = 0, _cooldown = 0;
  int _lastFrame = -1;
  int transitions = 0;
  int? lastTransitionFrame;
  String? lastTransitionReason;
  String reason = 'startup';
  int? sceneGpuTimeNs;
  CloudSceneFrameController(this.budget);
  int get level => _level;
  int get rayStride => _level == 2 ? 8 : 4;
  int get shadowCadence => 1 << _level;

  bool observe(FrameStats stats) {
    if (stats.frameId <= _lastFrame) return false;
    _lastFrame = stats.frameId;
    final profile = stats.profile;
    final ns = profile?.gpuTimeNs;
    if (profile?.status != 'complete' ||
        profile!.submissionCount != 1 ||
        profile.gpuTimeSource == 'unavailable' ||
        ns == null ||
        ns <= 0 ||
        stats.admission?.candidateReady == false) {
      sceneGpuTimeNs = null;
      _pressure = _recovery = 0;
      reason = 'timingUnavailable';
      return false;
    }
    sceneGpuTimeNs = ns;
    if (_cooldown > 0) {
      _cooldown--;
      return false;
    }
    final ratio = ns / (budget.target.inMicroseconds * 1000);
    _pressure = ratio > 1.15 ? _pressure + 1 : 0;
    _recovery = ratio < .75 ? _recovery + 1 : 0;
    final previous = _level;
    if (_pressure >= budget.pressureSamples && _level < 2) {
      _level++;
      reason = 'scenePressure';
    } else if (_recovery >= budget.recoverySamples && _level > 0) {
      _level--;
      reason = 'sceneHeadroom';
    }
    if (previous == _level) return false;
    transitions++;
    lastTransitionFrame = stats.frameId;
    lastTransitionReason = reason;
    _pressure = _recovery = 0;
    _cooldown = budget.cooldownSamples;
    return true;
  }

  Map<String, Object?> toJson() => {
    'targetSceneTimeUs': budget.target.inMicroseconds,
    'pressureSamples': budget.pressureSamples,
    'recoverySamples': budget.recoverySamples,
    'cooldownSamples': budget.cooldownSamples,
    'level': level,
    'rayStride': rayStride,
    'shadowCadence': shadowCadence,
    'sceneGpuTimeNs': sceneGpuTimeNs,
    'timingScope': 'completedSceneSubmissionExcludingShadowGraphs',
    'reason': reason,
    'transitions': transitions,
    'lastTransitionFrame': lastTransitionFrame,
    'lastTransitionReason': lastTransitionReason,
  };
}
