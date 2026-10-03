import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'character_animation.dart';

final class RootMotionDelta {
  final Vec3 translation;
  final double yaw;
  const RootMotionDelta(this.translation, this.yaw);
}

/// Extracts translation and Y-axis turning from an imported top-level root.
/// Use the same [process] closure for the base clip and every state clip.
final class RootMotion {
  final ModelInstance model;
  final int root;
  final bool vertical, rotation;
  late final ModelPose _rest = model.samplePose(initial: true);
  late final ModelPose Function(ModelPose) process = strip;
  RootMotion(
    this.model, {
    required this.root,
    this.vertical = false,
    this.rotation = true,
  }) {
    if (!identical(model.nodes[root]?.parent, model)) {
      throw ArgumentError('Root motion requires a top-level imported node.');
    }
  }
  static double _yaw(Quat q) =>
      math.atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z));
  Vec3 _select(Vec3 v) => Vec3(v.x, vertical ? v.y : 0, v.z);
  ModelPose strip(ModelPose pose) {
    final n = pose.nodes[root]!, rest = _rest.nodes[root]!;
    final yaw = _yaw(n.rotation) - _yaw(rest.rotation);
    return pose.withNodes({
      root: (
        position: Vec3(
          rest.position.x,
          vertical ? rest.position.y : n.position.y,
          rest.position.z,
        ),
        rotation: rotation
            ? Quat.axisAngle(const Vec3(0, 1, 0), -yaw) * n.rotation
            : n.rotation,
        scale: n.scale,
      ),
    });
  }

  /// Integrates signed playback travel; explicit seeks never create movement.
  RootMotionDelta sample(
    ModelAnimation animation,
    Duration start,
    Duration travel,
  ) {
    final length = animation.duration.inMicroseconds;
    if (length <= 0 || travel == Duration.zero) {
      return const RootMotionDelta(Vec3.zero, 0);
    }
    ({Vec3 position, double yaw}) at(int us) {
      final cycle = (us / length).floor();
      final phase = us - cycle * length;
      final a = model
          .samplePose(initial: true, animation: animation)
          .nodes[root]!;
      final b = model
          .samplePose(
            initial: true,
            animation: animation,
            time: animation.duration,
          )
          .nodes[root]!;
      final n = model
          .samplePose(
            initial: true,
            animation: animation,
            time: Duration(microseconds: phase),
          )
          .nodes[root]!;
      double angle(int time) {
        final channels = animation.channels.where(
          (c) => c.node == root && c.path == ModelAnimationPath.rotation,
        );
        if (channels.isEmpty || !rotation) return 0;
        final channel = channels.single;
        var previous = _yaw(a.rotation), total = 0.0;
        final times = <int>{
          0,
          for (final t in channel.times)
            if ((t * 1000000).round() < time) (t * 1000000).round(),
          time,
        }.toList()..sort();
        for (var i = 1; i < times.length; i++) {
          // Cubic rotation curves may turn between their authored keys.
          final samples =
              channel.interpolation == ModelInterpolation.cubicSpline ? 32 : 1;
          for (var part = 1; part <= samples; part++) {
            final us =
                times[i - 1] +
                ((times[i] - times[i - 1]) * part / samples).round();
            final q = channel.sample(Duration(microseconds: us));
            final current = _yaw(Quat(q[0], q[1], q[2], q[3]).normalized());
            var difference = current - previous;
            while (difference > math.pi) {
              difference -= 2 * math.pi;
            }
            while (difference < -math.pi) {
              difference += 2 * math.pi;
            }
            total += difference;
            previous = current;
          }
        }
        return total;
      }

      return (
        position: n.position + (b.position - a.position) * cycle.toDouble(),
        yaw: angle(phase) + angle(length) * cycle,
      );
    }

    final a = at(start.inMicroseconds),
        b = at(start.inMicroseconds + travel.inMicroseconds);
    return RootMotionDelta(
      _select(b.position - a.position),
      rotation ? b.yaw - a.yaw : 0,
    );
  }

  /// Advances the existing timeline clock once and returns blended local intent.
  RootMotionDelta advance(CharacterAnimationPlugin character, Duration step) {
    if (step <= Duration.zero || step > const Duration(milliseconds: 100)) {
      throw ArgumentError('Root motion needs a fixed step in (0, 100ms].');
    }
    final before = character.clocks;
    character.timeline.advance(step);
    final after = character.clocks;
    var movement = Vec3.zero, yaw = 0.0, total = 0.0;
    for (final state in character.states) {
      final a = before[state.id]!, b = after[state.id]!;
      final weight = (a.weight + b.weight) * .5;
      total += weight;
      for (final track in state.clip.tracks.whereType<ModelAnimationTrack>()) {
        if (!identical(track.target, model) || track.animation == null) {
          continue;
        }
        final d = sample(
          track.animation!,
          a.position,
          b.traversal - a.traversal,
        );
        movement += d.translation * weight;
        yaw += d.yaw * weight;
      }
    }
    final norm = math.max(1.0, total);
    return RootMotionDelta(movement / norm, yaw / norm);
  }
}
