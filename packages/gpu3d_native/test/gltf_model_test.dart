import 'dart:io';
import 'package:test/test.dart';
import 'support/gltf_model_checks.dart';

void main() {
  test(
    'glTF textures, shared views and scoped model lifetime',
    verifyGltfModels,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
