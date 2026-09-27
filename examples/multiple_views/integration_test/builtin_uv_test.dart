import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/gpu3d_native/test/support/builtin_uv_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'built-in UVs sample upright faces and sphere quadrants',
    (tester) async => verifyBuiltinUvs(),
  );
}
