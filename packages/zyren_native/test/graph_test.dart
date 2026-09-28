import 'dart:io';
import 'package:test/test.dart';
import 'support/graph_checks.dart';

void main() {
  test(
    'native uniform/storage layouts, pipeline reuse and edits',
    verifyNativeGraphBuffers,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'native compute-to-render graph, failed edit and independent lifetime',
    verifyNativeGraph,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
