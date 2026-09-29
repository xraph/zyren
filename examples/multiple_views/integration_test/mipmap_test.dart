import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/zyren_native/test/support/mipmap_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native resource mipmaps preserve color, alpha and odd extents',
    (tester) async => verifyResourceMips(),
  );
  testWidgets(
    'generated scene mipmaps survive shared ownership and minification',
    (tester) async => verifyGeneratedSceneMips(),
  );
}
