/// Versioned observations and bounded knowledge-filtered game sensors.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_capture/sensors.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_physics/zyren_physics.dart';

part 'src/contracts/observation.dart';
part 'src/contracts/action.dart';
part 'src/contracts/sensor_profile.dart';
part 'src/contracts/frame.dart';
part 'src/perception/snapshot.dart';
part 'src/perception/registry.dart';
part 'src/perception/vision.dart';
part 'src/perception/camera.dart';
part 'src/perception/image_preprocess.dart';
part 'src/perception/rays.dart';
part 'src/perception/grid.dart';
part 'src/perception/hearing.dart';
part 'src/perception/body.dart';
part 'src/perception/affordance.dart';
part 'src/perception/assembler.dart';

part 'src/brain/memory.dart';
part 'src/brain/belief.dart';
part 'src/brain/authoring.dart';
part 'src/brain/team.dart';
part 'src/brain/communication.dart';
part 'src/brain/goal.dart';
part 'src/brain/brain.dart';
part 'src/brain/utility.dart';
part 'src/brain/skill.dart';
part 'src/brain/scripted.dart';
part 'src/brain/action_decoder.dart';
part 'src/brain/training_actions.dart';
part 'src/brain/training_visual_profiles.dart';
part 'src/brain/visual_observation.dart';
part 'src/brain/policy_state.dart';
part 'src/brain/checkpoint.dart';
part 'src/brain/policy.dart';
part 'src/brain/policy_group.dart';
part 'src/brain/hybrid.dart';
part 'src/brain/decision_scheduler.dart';

void _name(String value) {
  if (value.trim().isEmpty || value.length > 128) {
    throw ArgumentError('Invalid identifier.');
  }
}

void _bounded(int value, int max, String name, {bool zero = false}) {
  if (value < (zero ? 0 : 1) || value > max) {
    throw RangeError.value(value, name);
  }
}

String _hash(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
Vec3 _local(Quat rotation, Vec3 vector) =>
    Quat(-rotation.x, -rotation.y, -rotation.z, rotation.w).rotate(vector);
