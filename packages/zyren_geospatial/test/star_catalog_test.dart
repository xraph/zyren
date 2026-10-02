import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'pinned Yale catalogue decodes source directions, magnitudes and colours',
    () {
      final catalog = StarCatalog.brightStars();
      expect(catalog.stars.length, 9096);
      for (final star in catalog.stars) {
        expect(star.directionECI.length, closeTo(1, 1e-12));
        expect(star.magnitude, inInclusiveRange(-2, 8));
      }
      final bytes = Uint8List(10);
      final view = ByteData.sublistView(bytes);
      view.setInt16(0, -32768, Endian.little);
      bytes[6] = 255;
      bytes[7] = 255;
      bytes[8] = 128;
      final custom = StarCatalog.fromBytes(bytes);
      bytes.fillRange(0, 10, 0);
      expect(custom.stars.single.directionECI.x, -1);
      expect(custom.stars.single.magnitude, 8);
      expect(custom.stars.single.color.g, closeTo(128 / 255, 1e-12));
      expect(() => catalog.stars.clear(), throwsUnsupportedError);
      expect(() => StarCatalog.fromBytes(Uint8List(11)), throwsArgumentError);
      expect(() => StarCatalog.fromBytes(Uint8List(10)), throwsArgumentError);
    },
  );
}
