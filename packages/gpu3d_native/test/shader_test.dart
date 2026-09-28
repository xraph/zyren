import 'dart:io';
import 'package:test/test.dart';
import 'support/shader_checks.dart';

void main() {
  test(
    'WGSL diagnostics, native cache and shared view lifetime',
    verifyNativeShaders,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'native compiler closes during accepted work without leaking',
    verifyShaderCloseWhilePending,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
