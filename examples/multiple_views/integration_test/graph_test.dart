import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/gpu3d_native/test/support/graph_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native render graph execution and ownership', (tester) async {
    await verifyNativeGraph();
    await verifyNativeGraphBuffers();
  });
}
