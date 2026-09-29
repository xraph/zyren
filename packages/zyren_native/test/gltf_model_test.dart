import 'dart:io';
import 'package:test/test.dart';
import 'support/gltf_model_checks.dart';
import 'support/gltf_pbr_checks.dart';
import 'support/morph_tangent_checks.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'generated morph tangent normal maps match absolute-pose pixels',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyMorphTangents(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test('glTF PBR and punctual light reference pixels', () async {
    final backend = await NativeBackend.create();
    try {
      await verifyGltfPbr(backend);
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
  test(
    'glTF textures, shared views and scoped model lifetime',
    verifyGltfModels,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
