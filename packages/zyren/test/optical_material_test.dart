import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test('thin-film factors and maps survive copies', () {
    final map = TextureMap(
      image: TextureImage.rgba(
        width: 1,
        height: 1,
        pixels: Uint8List.fromList([128, 64, 0, 255]),
        format: TextureFormat.rgba8Unorm,
      ),
    );
    final material = PhysicalMaterial(
      iridescence: .8,
      iridescenceIor: 1.4,
      iridescenceThicknessMinimum: 450,
      iridescenceThicknessMaximum: 100,
      dispersion: .7,
      iridescenceMap: map,
      iridescenceThicknessMap: map,
    );
    final copy = material.copyWith(roughness: .2);
    expect(copy.iridescence, .8);
    expect(copy.iridescenceIor, 1.4);
    expect(copy.iridescenceThicknessMinimum, 450);
    expect(copy.iridescenceThicknessMaximum, 100);
    expect(copy.dispersion, .7);
    expect(copy.textureMaps, [map, map]);
    expect(
      copy
          .copyWith(
            clearIridescenceMap: true,
            clearIridescenceThicknessMap: true,
          )
          .textureMaps,
      isEmpty,
    );
  });
  test('optical factors reject nonfinite and out-of-profile values', () {
    for (final bad in [-1.0, double.nan, double.infinity]) {
      expect(() => PhysicalMaterial(iridescence: bad), throwsArgumentError);
      expect(() => PhysicalMaterial(dispersion: bad), throwsArgumentError);
      expect(
        () => PhysicalMaterial(iridescenceThicknessMaximum: bad),
        throwsArgumentError,
      );
    }
    expect(() => PhysicalMaterial(iridescence: 1.01), throwsArgumentError);
    expect(() => PhysicalMaterial(iridescenceIor: .9), throwsArgumentError);
    expect(PhysicalMaterial().dispersion, 0);
    expect(PhysicalMaterial().iridescenceThicknessMaximum, 400);
  });
}
