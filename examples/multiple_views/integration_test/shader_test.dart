import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/gpu3d_native/test/support/shader_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native WGSL diagnostics and shared lifetime', (tester) async {
    await verifyNativeShaders();
    await verifyShaderCloseWhilePending();
  });
}
