import 'dart:io';
import 'package:test/test.dart';
import 'support/material_alpha_checks.dart';

void main() {
  test(
    'native masks, blending, depth and ordering use captured material state',
    verifyMaterialAlpha,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
