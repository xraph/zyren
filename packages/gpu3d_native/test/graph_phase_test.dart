import 'dart:io';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/graph_phase_checks.dart';

void main() {
  test(
    'compute prepares material textures before the same scene and postprocess frame',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyGraphPhases(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
