import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/gpu3d_native/test/support/pbr_checks.dart';
import '../../../packages/gpu3d_native/test/support/standard_maps_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('native PBR texture and lighting reference pixels', () async {
    final backend = await NativeBackend.create();
    try {
      await verifyPbr(backend);
      await verifyStandardMaps(backend);
    } finally {
      await backend.close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
