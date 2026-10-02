import 'dart:io';
import 'package:test/test.dart';
import 'support/scene_alpha_checks.dart';

void main() {
  test(
    'scene alpha survives blending, effects, resize and opaque transitions',
    verifySceneAlpha,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
