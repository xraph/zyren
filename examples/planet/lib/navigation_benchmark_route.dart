import 'dart:math' as math;
import 'package:zyren/zyren.dart';

const navigationPhases = ['stationary', 'rotate', 'drag', 'zoom', 'reversal'];
const navigationPhaseDurationUs = 12000000;
const navigationReversalUs = 6000000;

bool navigationAdaptiveClouds(String variant) => switch (variant) {
  'auto' || 'shadowsOff' || 'sparse' => true,
  'low' || 'medium' || 'high' => false,
  _ => throw ArgumentError.value(variant, 'variant'),
};

/// A bounded orbit with a velocity sign change at six seconds.
/// The other moving phases retain the established smooth sine trajectory.
double navigationWave(String phase, int elapsedUs) {
  final t = elapsedUs.clamp(0, navigationPhaseDurationUs);
  if (phase == 'stationary') return 0;
  if (phase == 'reversal') {
    return t <= navigationReversalUs
        ? t / navigationReversalUs
        : (navigationPhaseDurationUs - t) / navigationReversalUs;
  }
  return math.sin(2 * math.pi * t / navigationPhaseDurationUs);
}

/// A qualification liveness ceiling, not a target frame rate.
const navigationMaxReceiptGapUs = 1000000;

/// Returns a failure for incomplete measurement or unproven reverse motion.
String? navigationPhaseFailure(
  String phase,
  List<Map<String, Object?>> frames, {
  required int elapsedUs,
  int? appliedReversalUs,
}) {
  var previous = 0;
  for (final frame in frames) {
    final at = frame['phaseElapsedUs'] as int;
    if (at < previous || at - previous > navigationMaxReceiptGapUs) {
      return 'Accepted presentations exceeded the one-second liveness limit.';
    }
    previous = at;
  }
  if (elapsedUs - previous > navigationMaxReceiptGapUs ||
      previous < navigationPhaseDurationUs ||
      frames.length < 2) {
    return 'No sustained accepted presentation through the phase boundary.';
  }
  if (phase != 'reversal') return null;
  if (appliedReversalUs == null || appliedReversalUs < navigationReversalUs) {
    return 'The reversal command was not applied.';
  }
  final before = frames
      .where(
        (f) =>
            f['commandAppliedAtUs'] is int &&
            (f['commandAppliedAtUs'] as int) < navigationReversalUs &&
            f['cameraPosition'] is List,
      )
      .toList();
  final after = frames
      .where(
        (f) =>
            f['commandAppliedAtUs'] is int &&
            (f['commandAppliedAtUs'] as int) >= appliedReversalUs &&
            f['cameraPosition'] is List,
      )
      .toList();
  if (before.length < 2 ||
      after.length < 2 ||
      (before.last['commandedWave'] as num) <=
          (before.first['commandedWave'] as num) ||
      (after.last['commandedWave'] as num) >=
          (after.first['commandedWave'] as num)) {
    return 'Accepted source frames did not span both reversal directions.';
  }
  final a = before.first['cameraPosition'] as List;
  final b = before.last['cameraPosition'] as List;
  final c = after.first['cameraPosition'] as List;
  final d = after.last['cameraPosition'] as List;
  var dot = 0.0;
  for (var i = 0; i < 3; i++) {
    dot += ((b[i] as num) - (a[i] as num)) * ((d[i] as num) - (c[i] as num));
  }
  if (!dot.isFinite || dot >= 0) {
    return 'Accepted camera trajectory did not reverse direction.';
  }
  return null;
}

/// Bounded handoff from render receipts to accepted presentation receipts.
final class NavigationMotionFrames {
  final _frames =
      <int, ({int revision, int camera, Map<String, Object?> motion})>{};

  void record(
    int frameId,
    int revision,
    int camera,
    Map<String, Object?> motion,
  ) {
    _frames[frameId] = (
      revision: revision,
      camera: camera,
      motion: Map.unmodifiable(motion),
    );
    while (_frames.length > 2) {
      _frames.remove(_frames.keys.first);
    }
  }

  Map<String, Object?>? take(int frameId, int? revision, int? camera) {
    final frame = _frames.remove(frameId);
    return frame != null && frame.revision == revision && frame.camera == camera
        ? frame.motion
        : null;
  }

  void clear() => _frames.clear();
}

// Capture after normal navigation/clipping hooks, then match the accepted source.
final class NavigationMotionCapture extends ScenePlugin {
  @override
  String get id => 'qualification.navigation-motion';
  final frames = NavigationMotionFrames();
  Stopwatch? clock;
  int? appliedAtUs;
  double wave = 0;
  ({int number, int? appliedAtUs, double wave})? _preparing;

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (clock?.isRunning != true) return;
    _preparing = (number: frame.number, appliedAtUs: appliedAtUs, wave: wave);
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    final preparing = _preparing;
    _preparing = null;
    final source = stats.source, camera = context.camera;
    if (clock?.isRunning != true ||
        preparing?.number != info.number ||
        source == null ||
        source.cameraRevision != camera.revision ||
        source.cameraRuntimeId != camera.id) {
      return;
    }
    frames.record(
      stats.frameId,
      source.cameraRevision,
      source.cameraRuntimeId,
      {
        'commandAppliedAtUs': preparing!.appliedAtUs,
        'commandedWave': preparing.wave,
        'cameraPosition': [
          camera.position.x,
          camera.position.y,
          camera.position.z,
        ],
      },
    );
  }

  @override
  void detach(PluginContext context) => reset(null);

  void reset(Stopwatch? value) {
    if (!identical(clock, value)) clock?.stop();
    clock = value;
    appliedAtUs = null;
    wave = 0;
    _preparing = null;
    frames.clear();
  }
}
