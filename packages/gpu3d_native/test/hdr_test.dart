import 'dart:io';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/hdr_checks.dart';

void main() {
  test(
    'HDR resources, compute and exposure preserve bright light and alpha',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyHdr(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
