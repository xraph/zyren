import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'resource_scope_test.dart' as fixture;

class Device extends fixture.Device implements EnvironmentDevice {
  @override
  Uint8List encodeResourceKey(Object key) => Uint8List(32);
}

void main() {
  test(
    'environment maps validate layout, device, retention and scene registration',
    () async {
      final device = Device(), otherDevice = Device();
      final owner = ResourceScope(device),
          surviving = ResourceScope(device),
          foreign = ResourceScope(otherDevice);
      Future<GpuResource<Texture>> texture(
        ResourceScope scope, {
        bool volume = false,
      }) => scope.createTexture(
        TextureDescriptor(
          width: 4,
          height: 2,
          depth: volume ? 4 : 1,
          dimension: volume ? TextureDimension.d3 : TextureDimension.d2,
          format: TextureFormat.rgba16Float,
        ),
      );
      final diffuse = await texture(owner),
          specular = await texture(owner, volume: true),
          brdf = await texture(owner);
      final map = VolumeEnvironmentMap(
        irradiance: diffuse,
        specular: specular,
        brdf: brdf,
      );
      expect(map.encodeForDevice(device), hasLength(3));
      expect(() => map.encodeForDevice(otherDevice), throwsArgumentError);
      expect(
        () => VolumeEnvironmentMap(
          irradiance: diffuse,
          specular: brdf,
          brdf: brdf,
        ),
        throwsArgumentError,
      );
      final alien = await texture(foreign);
      expect(
        () => VolumeEnvironmentMap(
          irradiance: alien,
          specular: specular,
          brdf: brdf,
        ),
        throwsArgumentError,
      );
      expect(
        () => VolumeEnvironmentMap(
          irradiance: diffuse,
          specular: specular,
          brdf: brdf,
          intensity: double.nan,
        ),
        throwsArgumentError,
      );
      final retained = VolumeEnvironmentMap(
        irradiance: await surviving.retain(diffuse),
        specular: await surviving.retain(specular),
        brdf: await surviving.retain(brdf),
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(environment: retained);
      final registration = scene.addEnvironment(map);
      expect(scene.environment, same(map));
      expect(() => scene.addEnvironment(map), throwsStateError);
      registration.replace(retained);
      expect(scene.environment, same(retained));
      await owner.close();
      expect(() => registration.replace(map), throwsStateError);
      expect(scene.environment, same(retained));
      registration.dispose();
      expect(() => registration.replace(retained), throwsStateError);
      expect(scene.environment, same(retained));
      final next = scene.addEnvironment(retained);
      registration.dispose();
      expect(scene.environment, same(retained));
      next.dispose();
      expect(() => map.encodeForDevice(device), throwsStateError);
      expect(retained.encodeForDevice(device), hasLength(3));
      expect(() => scene.addEnvironment(map), throwsStateError);
      await surviving.close();
      await foreign.close();
      expect(device.live, isEmpty);
    },
  );
  test('linear environment images own input and reject invalid radiance', () {
    final values = Float32List.fromList([2, 1, .5, 1]);
    final image = EnvironmentImage(width: 1, height: 1, pixels: values);
    values[0] = 0;
    expect(Float32List.view(image.bytes.buffer)[0], 2);
    final copy = image.bytes;
    copy.fillRange(0, copy.length, 0);
    expect(Float32List.view(image.bytes.buffer)[0], 2);
    expect(
      () => EnvironmentImage(width: 4096, height: 1, pixels: values),
      throwsArgumentError,
    );
    values[0] = double.nan;
    expect(
      () => EnvironmentImage(width: 1, height: 1, pixels: values),
      throwsArgumentError,
    );
  });
}
