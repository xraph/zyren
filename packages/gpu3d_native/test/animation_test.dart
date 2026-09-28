import 'dart:io';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/animation_checks.dart';

void main() {
  test(
    'animated native poses preserve instance isolation and frozen captures',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyAnimation(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
