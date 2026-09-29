import 'dart:io';
import 'package:test/test.dart';
import 'support/mipmap_checks.dart';

void main() {
  final skip = Platform.environment['RUN_NATIVE_GPU'] != '1';
  test(
    'generated scene mips preserve linear light, sharing and budgets',
    verifyGeneratedSceneMips,
    skip: skip,
  );
  test(
    'native mipmaps filter linear light, transparent edges and odd extents',
    verifyResourceMips,
    skip: skip,
  );
}
