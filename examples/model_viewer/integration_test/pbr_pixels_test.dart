import 'dart:io';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/gpu3d_native/test/support/gltf_pbr_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('glTF PBR and punctual lights render native reference pixels', () async {
    final backend = Platform.isAndroid
        ? await NativeBackend.create()
        : await NativeMetalBackend.create();
    try {
      await verifyGltfPbr(backend);
    } finally {
      await backend.close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
