import 'dart:io';
import 'package:test/test.dart';
import 'support/primitive_checks.dart';

void main() {
  test(
    'native portable lines and points preserve size, clip and share resources',
    verifyPrimitives,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
