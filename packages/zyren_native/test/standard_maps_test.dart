import 'dart:io';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'support/standard_maps_checks.dart';

void main() {
  test(
    'standard texture maps, tangent deltas and hemisphere light render native pixels',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyStandardMaps(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
