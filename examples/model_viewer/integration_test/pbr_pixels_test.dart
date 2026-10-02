import 'dart:io';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/zyren_native/test/support/gltf_pbr_checks.dart';
import '../../../packages/zyren_native/test/support/vertex_colors_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('glTF PBR and punctual lights render native reference pixels', () async {
    final backend = Platform.isAndroid
        ? await NativeBackend.create()
        : await NativeMetalBackend.create();
    try {
      await verifyGltfPbr(backend);
      await verifyVertexColors(backend);
    } finally {
      await backend.close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
