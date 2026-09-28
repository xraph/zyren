import 'dart:io';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/pbr_reference_checks.dart';

void main() {
  test(
    'native linear radiance matches glTF material lobes across angles and roughness',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyPbrReference(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
