import 'dart:io';
import 'package:test/test.dart';
import 'support/graph_checks.dart';
import 'support/plugin_graph_checks.dart';

void main() {
  test(
    'plugin-owned graphs share typed outputs and retire independently across engines',
    verifyPluginGraphs,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
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
