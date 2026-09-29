import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

void main() {
  test('glass keeps coverage separate from transmission and volume', () {
    final glass = PhysicalMaterial(
      transmission: 1,
      thickness: .5,
      attenuationColor: const Color3(.5, .8, 1),
      attenuationDistance: 2,
    );
    expect(glass.opacity, 1);
    expect(glass.alphaMode, MaterialAlphaMode.opaque);
    final changed = glass.copyWith(thickness: 1);
    expect(changed.transmission, 1);
    expect(changed.attenuationDistance, 2);
    expect(changed.attenuationColor, const Color3(.5, .8, 1));
    expect(PhysicalMaterial().attenuationDistance, double.infinity);
    for (final value in [-1.0, 1.1, double.nan, double.infinity]) {
      expect(() => PhysicalMaterial(transmission: value), throwsArgumentError);
    }
    for (final value in [-1.0, double.nan, double.infinity]) {
      expect(() => PhysicalMaterial(thickness: value), throwsArgumentError);
    }
    for (final value in [-1.0, 0.0, double.nan]) {
      expect(
        () => PhysicalMaterial(attenuationDistance: value),
        throwsArgumentError,
      );
    }
  });
  test('transmission maps are owned and have explicit copy removal', () {
    final map = TextureMap(
      image: TextureImage.rgba(
        format: TextureFormat.rgba8Unorm,
        width: 1,
        height: 1,
        pixels: Uint8List.fromList([128, 64, 0, 255]),
      ),
    );
    final glass = PhysicalMaterial(
      transmission: 1,
      transmissionMap: map,
      thicknessMap: map,
    );
    expect(glass.textureMaps, [map, map]);
    expect(glass.copyWith(clearTransmissionMap: true).textureMaps, [map]);
    expect(glass.copyWith(clearThicknessMap: true).transmissionMap, same(map));
  });
}
