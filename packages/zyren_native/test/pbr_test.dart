import 'dart:io';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'support/pbr_checks.dart';

void main() {
  test(
    'standard materials and punctual light edits render through native packets',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyPbr(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
