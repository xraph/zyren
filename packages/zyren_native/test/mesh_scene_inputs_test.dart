import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/mesh_scene_input_checks.dart';

void main() {
  test(
    'custom surfaces sample current opaque HDR color and depth across views and modes',
    () async {
      final backend = await NativeBackend.create();
      try {
        for (final scale in [1.0, .5, .75]) {
          await verifyMeshSceneInputs(backend, captureScale: scale);
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
