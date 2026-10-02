import 'dart:io';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'support/gltf_deformation_checks.dart';

void main() {
  test(
    'imported skin and animated morphs match native pixels with independent instances',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyGltfDeformation(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
