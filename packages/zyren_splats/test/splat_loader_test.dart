import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_splats/zyren_splats.dart';

void main() {
  test(
    'binary splat import decodes covariance and explicitly converts color',
    () async {
      final bytes = Uint8List(32), view = ByteData.sublistView(bytes);
      final values = [1.0, 2.0, 3.0, .2, .1, .3];
      for (var i = 0; i < 6; i++) {
        view.setFloat32(i * 4, values[i], Endian.little);
      }
      bytes.setRange(24, 32, [128, 255, 0, 128, 255, 128, 128, 128]);
      final loader = BinarySplatLoader(
        sourceVersion: 'v1',
        colorEncoding: SplatColorEncoding.srgb,
      );
      final data = await loader.parse(
        bytes,
        sourceUri: Uri.parse('asset:scene.splat'),
      );
      final s = data.splats.single;
      expect(s.mean, const Vec3(1, 2, 3));
      expect(s.covariance.xx, closeTo(.04, 1e-8));
      expect(s.covariance.yy, closeTo(.01, 1e-8));
      expect(s.color.r, closeTo(.2158605001, 1e-9));
      expect(s.color.g, 1);
      expect(s.opacity, 128 / 255);
      expect(data.identityAt(0).$3, 0);
      await expectLater(
        loader.parse(Uint8List(31), sourceUri: Uri.parse('asset:bad')),
        throwsA(isA<AssetLoadException>()),
      );
      view.setFloat32(12, -1, Endian.little);
      await expectLater(
        loader.parse(bytes, sourceUri: Uri.parse('asset:bad')),
        throwsA(isA<AssetLoadException>()),
      );
    },
  );
}
