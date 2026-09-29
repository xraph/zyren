import 'dart:io';
import 'package:test/test.dart';
import 'support/frame_graph_checks.dart';

void main() {
  test(
    'compute postprocessing uses scene color within the frame',
    () => verifyFrameGraph(compute: true),
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'scene passes compose into native frame output without author scopes',
    verifyFrameGraph,
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
