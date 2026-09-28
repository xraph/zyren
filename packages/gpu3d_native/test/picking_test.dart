import 'dart:io';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/picking_checks.dart';

void main() {
  test(
    'picks match native skin, morph, mirrored instance and layer pixels',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyPickingPixels(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
