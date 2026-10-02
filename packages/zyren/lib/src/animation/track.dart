part of 'clip.dart';

enum KeyframeInterpolation { step, linear, cubicSpline }

enum AnimationProperty { position, rotation, scale, morphWeights }

typedef TransformProperty = AnimationProperty;

/// A channel targets a stable ID resolved by the mixer's node map, never a name
/// search or a reference to an object in a different model instance.
sealed class KeyframeTrack<T extends Object> {
  final String target;
  final TransformProperty property;
  final KeyframeInterpolation interpolation;
  final List<double> times;
  final List<T> values;
  final List<T>? inTangents, outTangents;
  KeyframeTrack._({
    required this.target,
    required this.property,
    required List<double> times,
    required List<T> values,
    required this.interpolation,
    List<T>? inTangents,
    List<T>? outTangents,
  }) : times = _boundedCopy(times, 1000000, 'times'),
       values = _boundedCopy(values, 1000000, 'values'),
       inTangents = inTangents == null
           ? null
           : _boundedCopy(inTangents, 1000000, 'inTangents'),
       outTangents = outTangents == null
           ? null
           : _boundedCopy(outTangents, 1000000, 'outTangents') {
    if (target.isEmpty ||
        times.isEmpty ||
        times.length > 1000000 ||
        values.length != times.length) {
      throw ArgumentError(
        'Tracks need a target and 1..1000000 matching keys and values.',
      );
    }
    var previous = -1.0;
    for (final time in times) {
      if (!time.isFinite || time < 0 || time > 1e9 || time <= previous) {
        throw ArgumentError(
          'Key times must be finite, nonnegative, strictly increasing seconds up to 1e9.',
        );
      }
      previous = time;
    }
    if (interpolation == KeyframeInterpolation.cubicSpline) {
      if (times.length < 2 ||
          inTangents?.length != times.length ||
          outTangents?.length != times.length) {
        throw ArgumentError(
          'Cubic tracks need at least two keys and both tangents at every key.',
        );
      }
    } else if (inTangents != null || outTangents != null) {
      throw ArgumentError('Tangents are only used by cubic tracks.');
    }
  }
  T sample(double seconds) {
    if (!seconds.isFinite) throw ArgumentError.value(seconds, 'seconds');
    if (seconds <= times.first) return values.first;
    if (seconds >= times.last) return values.last;
    var low = 0, high = times.length - 1;
    while (high - low > 1) {
      final mid = (low + high) ~/ 2;
      if (times[mid] <= seconds) {
        low = mid;
      } else {
        high = mid;
      }
    }
    if (seconds == times[low] || interpolation == KeyframeInterpolation.step) {
      return values[low];
    }
    final duration = times[high] - times[low];
    final t = (seconds - times[low]) / duration;
    return interpolation == KeyframeInterpolation.linear
        ? _linear(values[low], values[high], t)
        : _cubic(
            values[low],
            outTangents![low],
            values[high],
            inTangents![high],
            t,
            duration,
          );
  }

  T _linear(T a, T b, double t);
  T _cubic(T a, T outgoing, T b, T incoming, double t, double duration);
}

final class VectorKeyframeTrack extends KeyframeTrack<Vec3> {
  VectorKeyframeTrack.position({
    required String target,
    required List<double> times,
    required List<Vec3> values,
    KeyframeInterpolation interpolation = KeyframeInterpolation.linear,
    List<Vec3>? inTangents,
    List<Vec3>? outTangents,
  }) : this._(
         TransformProperty.position,
         target,
         times,
         values,
         interpolation,
         inTangents,
         outTangents,
       );
  VectorKeyframeTrack.scale({
    required String target,
    required List<double> times,
    required List<Vec3> values,
    KeyframeInterpolation interpolation = KeyframeInterpolation.linear,
    List<Vec3>? inTangents,
    List<Vec3>? outTangents,
  }) : this._(
         TransformProperty.scale,
         target,
         times,
         values,
         interpolation,
         inTangents,
         outTangents,
       );
  VectorKeyframeTrack._(
    TransformProperty property,
    String target,
    List<double> times,
    List<Vec3> values,
    KeyframeInterpolation interpolation,
    List<Vec3>? inTangents,
    List<Vec3>? outTangents,
  ) : super._(
        target: target,
        property: property,
        times: times,
        values: values,
        interpolation: interpolation,
        inTangents: inTangents,
        outTangents: outTangents,
      ) {
    if (values
            .followedBy(inTangents ?? const [])
            .followedBy(outTangents ?? const [])
            .any((v) => !v.isFinite) ||
        (property == TransformProperty.scale &&
            values.any((v) => v.x == 0 || v.y == 0 || v.z == 0))) {
      throw ArgumentError(
        'Vector keys and tangents must be finite; scale keys must be nonsingular.',
      );
    }
  }
  @override
  Vec3 _linear(Vec3 a, Vec3 b, double t) => a * (1 - t) + b * t;
  @override
  Vec3 _cubic(
    Vec3 a,
    Vec3 outgoing,
    Vec3 b,
    Vec3 incoming,
    double t,
    double duration,
  ) {
    final t2 = t * t, t3 = t2 * t;
    return a * (2 * t3 - 3 * t2 + 1) +
        outgoing * (duration * (t3 - 2 * t2 + t)) +
        b * (-2 * t3 + 3 * t2) +
        incoming * (duration * (t3 - t2));
  }
}

final class QuaternionKeyframeTrack extends KeyframeTrack<Quat> {
  QuaternionKeyframeTrack({
    required super.target,
    required super.times,
    required List<Quat> values,
    super.interpolation = KeyframeInterpolation.linear,
    List<Quat>? inTangents,
    List<Quat>? outTangents,
  }) : super._(
         property: TransformProperty.rotation,
         values: _quaternionKeys(values),
         inTangents: inTangents,
         outTangents: outTangents,
       ) {
    if ((inTangents ?? const <Quat>[])
        .followedBy(outTangents ?? const [])
        .any((q) => !q.isFinite)) {
      throw ArgumentError('Quaternion tangents must be finite.');
    }
  }
  @override
  Quat _linear(Quat a, Quat b, double t) => _slerp(a, b, t);
  @override
  Quat _cubic(
    Quat a,
    Quat outgoing,
    Quat b,
    Quat incoming,
    double t,
    double duration,
  ) {
    final t2 = t * t, t3 = t2 * t;
    final x = 2 * t3 - 3 * t2 + 1,
        y = duration * (t3 - 2 * t2 + t),
        z = -2 * t3 + 3 * t2,
        w = duration * (t3 - t2);
    return Quat(
      a.x * x + outgoing.x * y + b.x * z + incoming.x * w,
      a.y * x + outgoing.y * y + b.y * z + incoming.y * w,
      a.z * x + outgoing.z * y + b.z * z + incoming.z * w,
      a.w * x + outgoing.w * y + b.w * z + incoming.w * w,
    ).normalized();
  }
}

List<Quat> _quaternionKeys(List<Quat> values) {
  if (values.length > 1000000) {
    throw ArgumentError('Quaternion tracks support at most one million keys.');
  }
  return values.map((q) => q.normalized()).toList();
}

Quat _slerp(Quat a, Quat b, double t) {
  var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  if (dot < 0) {
    b = Quat(-b.x, -b.y, -b.z, -b.w);
    dot = -dot;
  }
  var x = 1 - t, y = t;
  if (dot < 1 - 1e-10) {
    final angle = math.acos(dot.clamp(0.0, 1.0)),
        divisor = math.sqrt(1 - dot * dot);
    x = math.sin((1 - t) * angle) / divisor;
    y = math.sin(t * angle) / divisor;
  }
  return Quat(
    a.x * x + b.x * y,
    a.y * x + b.y * y,
    a.z * x + b.z * y,
    a.w * x + b.w * y,
  ).normalized();
}

/// Animates all morph weights on a mesh or an explicit primitive binding.
final class MorphWeightKeyframeTrack extends KeyframeTrack<List<double>> {
  int get targetCount => values.first.length;
  MorphWeightKeyframeTrack({
    required super.target,
    required super.times,
    required List<List<double>> values,
    super.interpolation = KeyframeInterpolation.linear,
    List<List<double>>? inTangents,
    List<List<double>>? outTangents,
  }) : super._(
         property: AnimationProperty.morphWeights,
         values: _weightKeys(values, bounded: true),
         inTangents: inTangents == null ? null : _weightKeys(inTangents),
         outTangents: outTangents == null ? null : _weightKeys(outTangents),
       ) {
    if (this.values
        .followedBy(this.inTangents ?? const [])
        .followedBy(this.outTangents ?? const [])
        .any((value) => value.length != targetCount)) {
      throw ArgumentError('Morph keys and tangents must have matching widths.');
    }
  }
  @override
  List<double> _linear(List<double> a, List<double> b, double t) =>
      List.unmodifiable([
        for (var i = 0; i < a.length; i++) a[i] * (1 - t) + b[i] * t,
      ]);
  @override
  List<double> _cubic(
    List<double> a,
    List<double> outgoing,
    List<double> b,
    List<double> incoming,
    double t,
    double duration,
  ) {
    final t2 = t * t, t3 = t2 * t;
    return List.unmodifiable([
      for (var i = 0; i < a.length; i++)
        a[i] * (2 * t3 - 3 * t2 + 1) +
            outgoing[i] * (duration * (t3 - 2 * t2 + t)) +
            b[i] * (-2 * t3 + 3 * t2) +
            incoming[i] * (duration * (t3 - t2)),
    ]);
  }
}

List<List<double>> _weightKeys(
  List<List<double>> keys, {
  bool bounded = false,
}) {
  var count = 0;
  if (keys.length > 1000000) throw ArgumentError('Too many morph keys.');
  for (final key in keys) {
    count += key.length;
    if (key.isEmpty ||
        key.length > 64 ||
        count > 1000000 ||
        key.any((v) => !v.isFinite || (bounded && v.abs() > 1e6))) {
      throw ArgumentError(
        'Morph tracks require 1..64 finite weights per key, up to one million components; key magnitudes cannot exceed 1e6.',
      );
    }
  }
  return List.unmodifiable(keys.map((key) => List<double>.unmodifiable(key)));
}
