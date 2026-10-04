/// Captured-camera estimates, authored map pins and shared navigation control.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_physics/zyren_physics.dart';

part 'src/visual_v2/profile.dart';
part 'src/visual_v2/estimate.dart';
part 'src/visual_v2/map.dart';
part 'src/visual_v2/control.dart';
part 'src/visual_v2/policy.dart';

String _pin(Object value) => crypto.sha256
    .convert(utf8.encode(jsonEncode(_canonical(value))))
    .toString();
Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is Iterable) return value.map(_canonical).toList();
  return value;
}

void _sha(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw ArgumentError('Expected SHA-256 pin.');
  }
}

void _name(String value) {
  if (value.isEmpty || value.length > 128 || value.trim() != value) {
    throw ArgumentError('Invalid bounded identity.');
  }
}

void _finite(Vec3 value) {
  if (!value.isFinite || value.storage.any((v) => v.abs() > 10000)) {
    throw ArgumentError('Position or velocity exceeds bounds.');
  }
}

Quat _inverse(Quat value) => Quat(-value.x, -value.y, -value.z, value.w);
