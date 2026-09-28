import 'dart:async';
import 'dart:math' as math;
import '../math/vec3.dart';
import '../math/quat.dart';
import '../scene/scene.dart';
import '../plugins/engine.dart';
import '../plugins/registration.dart';
part 'track.dart';
part 'mixer.dart';
part 'action.dart';
part 'events.dart';
part 'system.dart';

/// Immutable tracks shared by independent mixers. Times are seconds.
final class AnimationClip {
  final String? name;
  final List<KeyframeTrack> tracks;
  final double durationSeconds;
  Duration get duration =>
      Duration(microseconds: (durationSeconds * 1e6).round());
  AnimationClip({
    this.name,
    required List<KeyframeTrack> tracks,
    double? durationSeconds,
  }) : tracks = _boundedCopy(tracks, 4096, 'tracks'),
       durationSeconds =
           durationSeconds ??
           tracks.fold<double>(
             0,
             (end, track) => math.max(end, track.times.last),
           ) {
    if (tracks.length > 4096 ||
        tracks.fold<int>(0, (n, t) => n + t.times.length) > 1000000) {
      throw ArgumentError(
        'A clip supports 4096 tracks and one million keyframes.',
      );
    }
    final channels = <(String, TransformProperty)>{};
    for (final track in tracks) {
      if (!channels.add((track.target, track.property))) {
        throw ArgumentError(
          'Duplicate animation channel: ${track.target}.${track.property.name}',
        );
      }
    }
    if (!this.durationSeconds.isFinite ||
        this.durationSeconds < 0 ||
        this.durationSeconds > 1e9 ||
        tracks.any((track) => track.times.last > this.durationSeconds)) {
      throw ArgumentError(
        'Clip duration must include every key and be within [0, 1e9] seconds.',
      );
    }
  }
}

List<T> _boundedCopy<T>(List<T> values, int limit, String name) {
  if (values.length > limit) {
    throw ArgumentError.value(values.length, name, 'At most $limit entries.');
  }
  return List.unmodifiable(values);
}
