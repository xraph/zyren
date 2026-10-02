import 'dart:math' as math;
import 'package:zyren/zyren.dart';

enum ModelInterpolation { step, linear, cubicSpline }

enum ModelAnimationPath { translation, rotation, scale, weights }

/// Immutable glTF animation data. Times are seconds, tangents are per second.
final class ModelAnimationChannel {
  final int node, components;
  final ModelAnimationPath path;
  final ModelInterpolation interpolation;
  final List<double> times, values;
  ModelAnimationChannel({
    required this.node,
    required this.path,
    required this.components,
    required this.interpolation,
    required Iterable<double> times,
    required Iterable<double> values,
  }) : times = List.unmodifiable(times),
       values = List.unmodifiable(values) {
    final factor = interpolation == ModelInterpolation.cubicSpline ? 3 : 1;
    if ((path == ModelAnimationPath.rotation && components != 4) ||
        (path != ModelAnimationPath.rotation &&
            path != ModelAnimationPath.weights &&
            components != 3) ||
        node < 0 ||
        components < 1 ||
        this.times.isEmpty ||
        this.values.length != this.times.length * components * factor ||
        this.values.any((v) => !v.isFinite) ||
        this.times.any((v) => !v.isFinite || v < 0)) {
      throw ArgumentError('Invalid animation channel storage.');
    }
    for (var i = 1; i < this.times.length; i++) {
      if (this.times[i] <= this.times[i - 1]) {
        throw ArgumentError('Animation times must increase.');
      }
    }
  }

  List<double> sample(Duration time) {
    final seconds = time.inMicroseconds / Duration.microsecondsPerSecond;
    var low = 0, high = times.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (times[mid] <= seconds) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final a = low, b = math.min(a + 1, times.length - 1);
    final span = b == a ? 1.0 : times[b] - times[a];
    final t = b == a ? 0.0 : ((seconds - times[a]) / span).clamp(0.0, 1.0);
    final cubic = interpolation == ModelInterpolation.cubicSpline;
    double at(int key, int component, [int slot = 1]) =>
        values[(key * (cubic ? 3 : 1) + (cubic ? slot : 0)) * components +
            component];
    if (path == ModelAnimationPath.rotation &&
        interpolation == ModelInterpolation.linear) {
      final left = Quat(at(a, 0), at(a, 1), at(a, 2), at(a, 3)).normalized();
      var right = Quat(at(b, 0), at(b, 1), at(b, 2), at(b, 3)).normalized();
      var dot =
          left.x * right.x +
          left.y * right.y +
          left.z * right.z +
          left.w * right.w;
      if (dot < 0) {
        right = Quat(-right.x, -right.y, -right.z, -right.w);
        dot = -dot;
      }
      var x = 1 - t, y = t;
      if (dot < .9995) {
        final angle = math.acos(dot.clamp(-1.0, 1.0));
        x = math.sin((1 - t) * angle) / math.sin(angle);
        y = math.sin(t * angle) / math.sin(angle);
      }
      final q = Quat(
        left.x * x + right.x * y,
        left.y * x + right.y * y,
        left.z * x + right.z * y,
        left.w * x + right.w * y,
      ).normalized();
      return [q.x, q.y, q.z, q.w];
    }
    final result = [
      for (var c = 0; c < components; c++)
        interpolation == ModelInterpolation.step
            ? at(a, c)
            : cubic
            ? (2 * t * t * t - 3 * t * t + 1) * at(a, c) +
                  (t * t * t - 2 * t * t + t) * span * at(a, c, 2) +
                  (-2 * t * t * t + 3 * t * t) * at(b, c) +
                  (t * t * t - t * t) * span * at(b, c, 0)
            : at(a, c) * (1 - t) + at(b, c) * t,
    ];
    if (path == ModelAnimationPath.rotation) {
      final q = Quat(result[0], result[1], result[2], result[3]).normalized();
      return [q.x, q.y, q.z, q.w];
    }
    return result;
  }
}

final class ModelAnimationEvent {
  final Duration time;
  final String id;
  final String? label;
  const ModelAnimationEvent(this.time, {required this.id, this.label});
}

final class ModelAnimation {
  final String? name;
  final List<ModelAnimationChannel> channels;
  final List<ModelAnimationEvent> events;
  late final Duration duration = Duration(
    microseconds:
        (channels.fold<double>(
                  0,
                  (end, channel) => math.max(end, channel.times.last),
                ) *
                1000000)
            .round(),
  );
  ModelAnimation({
    this.name,
    required Iterable<ModelAnimationChannel> channels,
    Iterable<ModelAnimationEvent> events = const [],
  }) : channels = List.unmodifiable(channels),
       events = List.unmodifiable(events);
}

final class ModelSkin {
  final List<int> joints;
  final List<Mat4> inverseBindMatrices;
  ModelSkin(Iterable<int> joints, Iterable<Mat4> inverseBindMatrices)
    : joints = List.unmodifiable(joints),
      inverseBindMatrices = List.unmodifiable(inverseBindMatrices);
}

final class PrimitiveDeformation {
  final List<List<double>> morphPositions, morphNormals, morphTangents;
  final List<int> joints;
  final List<double> weights;
  final bool generatedNormals;
  PrimitiveDeformation({
    Iterable<List<double>> morphPositions = const [],
    Iterable<List<double>> morphNormals = const [],
    Iterable<List<double>> morphTangents = const [],
    this.generatedNormals = false,
    Iterable<int> joints = const [],
    Iterable<double> weights = const [],
  }) : morphPositions = List.unmodifiable(
         morphPositions.map((v) => List<double>.unmodifiable(v)),
       ),
       morphNormals = List.unmodifiable(
         morphNormals.map((v) => List<double>.unmodifiable(v)),
       ),
       morphTangents = List.unmodifiable(
         morphTangents.map((v) => List<double>.unmodifiable(v)),
       ),
       joints = List.unmodifiable(joints),
       weights = List.unmodifiable(weights);
  bool get isEmpty => morphPositions.isEmpty && joints.isEmpty;
}
