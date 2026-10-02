import 'dart:io';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'support/vertex_colors_checks.dart';

void main() {
  test(
    'native vertex colors, alpha, updates, primitive clipping and shadows',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyVertexColors(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
