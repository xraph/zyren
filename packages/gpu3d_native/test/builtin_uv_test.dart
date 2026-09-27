import 'dart:io';
import 'package:test/test.dart';
import 'support/builtin_uv_checks.dart';

void main() {
  test(
    'built-in box faces and sphere quadrants sample native textures',
    verifyBuiltinUvs,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
