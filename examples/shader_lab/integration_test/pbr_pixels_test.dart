import 'dart:io';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/gpu3d_native/test/support/pbr_checks.dart';
import '../../../packages/gpu3d_native/test/support/pbr_reference_checks.dart';
import '../../../packages/gpu3d_native/test/support/standard_maps_checks.dart';
import '../../../packages/gpu3d_native/test/support/hdr_checks.dart';
import '../../../packages/gpu3d_native/test/support/hdr_asset_checks.dart';
import '../../../packages/gpu3d_native/test/support/environment_checks.dart';
import '../../../packages/gpu3d_native/test/support/shadow_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('native PBR texture and lighting reference pixels', () async {
    final backend = Platform.isAndroid
        ? await NativeBackend.create()
        : await NativeMetalBackend.create();
    try {
      await verifyPbr(backend);
      await verifyPbrReference(backend);
      await verifyStandardMaps(backend);
      await verifyHdr(backend);
      await verifyHdrAsset(backend);
      await verifyEnvironment(backend);
      await verifyShadows(backend);
    } finally {
      await backend.close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
