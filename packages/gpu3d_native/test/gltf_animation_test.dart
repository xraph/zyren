import 'dart:io';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/gltf_animation_checks.dart';

void main() {
  test(
    'imported native animation preserves instances and frozen frames',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyGltfAnimation(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
