part of 'clip.dart';

enum AnimationBlendMode { normal, additive }

Object _animationIdentity(Object value) => value is Quat
    ? Quat.identity
    : value is List<double>
    ? List<double>.filled(value.length, 0, growable: false)
    : Vec3.zero;

Object _animationOffset(Object value, Object reference) {
  if (value is Quat) {
    final q = (reference as Quat).normalized();
    return (Quat(-q.x, -q.y, -q.z, q.w) * value).normalized();
  }
  if (value is List<double>) {
    final rest = reference as List<double>;
    return List<double>.unmodifiable([
      for (var i = 0; i < value.length; i++) value[i] - rest[i],
    ]);
  }
  return (value as Vec3) - (reference as Vec3);
}

Object _addAnimationValue(Object base, Object offset, double weight) {
  if (base is Quat) {
    return (base * _slerp(Quat.identity, offset as Quat, weight)).normalized();
  }
  if (base is List<double>) {
    final delta = offset as List<double>;
    return List<double>.unmodifiable([
      for (var i = 0; i < base.length; i++) base[i] + delta[i] * weight,
    ]);
  }
  return (base as Vec3) + (offset as Vec3) * weight;
}
