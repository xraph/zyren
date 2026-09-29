import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/zyren_native/test/support/material_side_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native sidedness, mirrors and back-face lighting',
    (tester) async => verifyMaterialSides(),
  );
}
