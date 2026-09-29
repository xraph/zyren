import 'dart:io';
import 'package:test/test.dart';
import 'support/material_side_checks.dart';

void main() {
  test(
    'native sidedness, mirrored hierarchies and back-face lighting',
    verifyMaterialSides,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
