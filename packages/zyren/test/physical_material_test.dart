import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

class StandardOnlyRenderer extends TestRenderer {
  StandardOnlyRenderer() : super([]);
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'standard only',
    features: {RenderFeature.standardMaterials},
    maxDimension: 64,
  );
}

void main() {
  test(
    'physical capability fails before an unsupported backend receives the scene',
    () async {
      final renderer = StandardOnlyRenderer();
      final mesh = Mesh(PlaneGeometry(), PhysicalMaterial());
      final engine = await SceneEngine.create(
        scene: Scene()..add(mesh),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
      );
      try {
        await expectLater(
          engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31),
          throwsA(isA<SceneException>()),
        );
        expect(renderer.renders, 0);
        mesh.visible = false;
        await engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31);
        expect(renderer.renders, 1);
      } finally {
        await engine.dispose();
      }
    },
  );

  test('physical copies retain their layers through a standard reference', () {
    final StandardMaterial material = PhysicalMaterial(
      ior: 2.2,
      specularIntensity: .7,
      specularColor: const Color3(.8, .4, .2),
      clearcoat: .8,
      clearcoatRoughness: .2,
      sheenColor: const Color3(.3, .1, .2),
      sheenRoughness: .6,
      anisotropy: .5,
      anisotropyRotation: math.pi / 4,
      metallic: .3,
      roughness: .4,
    );
    final copy = material.copyWith(roughness: .9) as PhysicalMaterial;
    expect(copy.ior, 2.2);
    expect(copy.specularIntensity, .7);
    expect(copy.specularColor.toList(), [.8, .4, .2]);
    expect(copy.clearcoat, .8);
    expect(copy.clearcoatRoughness, .2);
    expect(copy.sheenColor.toList(), [.3, .1, .2]);
    expect(copy.sheenRoughness, .6);
    expect(copy.anisotropy, .5);
    expect(copy.anisotropyRotation, math.pi / 4);
    expect(copy.metallic, .3);
    expect(copy.roughness, .9);
  });

  test('rejects invalid factors before frame capture', () {
    for (final value in [double.nan, double.infinity, -.1, 1.1]) {
      expect(() => PhysicalMaterial(clearcoat: value), throwsArgumentError);
      expect(
        () => PhysicalMaterial(clearcoatRoughness: value),
        throwsArgumentError,
      );
      expect(
        () => PhysicalMaterial(sheenRoughness: value),
        throwsArgumentError,
      );
      expect(
        () => PhysicalMaterial(specularIntensity: value),
        throwsArgumentError,
      );
      expect(() => PhysicalMaterial(anisotropy: value), throwsArgumentError);
    }
    expect(() => PhysicalMaterial(ior: .9), throwsArgumentError);
    expect(() => PhysicalMaterial(ior: double.infinity), throwsArgumentError);
    expect(
      () => PhysicalMaterial(anisotropyRotation: double.nan),
      throwsArgumentError,
    );
  });

  test('every physical edit reaches a delta without geometry uploads', () {
    final scene = Scene();
    final mesh = scene.add(Mesh(PlaneGeometry(), PhysicalMaterial()));
    final encoder = ScenePacketEncoder(viewId: 1);
    EncodedScenePacket capture() => encoder.encode(
      FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(31, 31),
      ),
    );
    encoder.accept(capture());
    for (final material in [
      PhysicalMaterial(ior: 2),
      PhysicalMaterial(specularIntensity: .5),
      PhysicalMaterial(specularColor: const Color3(1, 0, 0)),
      PhysicalMaterial(clearcoat: 1),
      PhysicalMaterial(clearcoatRoughness: .2),
      PhysicalMaterial(sheenColor: const Color3(1, 0, 0)),
      PhysicalMaterial(sheenRoughness: .3),
      PhysicalMaterial(anisotropyRotation: .3),
      StandardMaterial(),
    ]) {
      mesh.material = material;
      final packet = capture();
      expect(packet.changedMeshes, 1);
      expect(packet.uploadedBytes, 0);
      encoder.accept(packet);
      expect(capture().changedMeshes, 0);
    }
  });
  test(
    'physical maps retain texture ownership, validate storage and enter scene deltas',
    () {
      final map = TextureMap(
        image: TextureImage.rgba(
          width: 1,
          height: 1,
          pixels: Uint8List.fromList([80, 120, 190, 128]),
          format: TextureFormat.rgba8Unorm,
        ),
      );
      final material = PhysicalMaterial(
        clearcoat: 1,
        clearcoatMap: map,
        clearcoatNormalScale: .5,
        specularColor: const Color3(2, 1, .5),
        ior: 0,
      );
      final mesh = Mesh(PlaneGeometry(), material), scene = Scene();
      scene.add(mesh);
      final encoder = ScenePacketEncoder(viewId: 7),
          camera = PerspectiveCamera();
      EncodedScenePacket capture() => encoder.encode(
        FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: PhysicalSize(7, 7),
        ),
      );
      final initial = capture();
      encoder.accept(initial);
      expect(capture().uploadedBytes, 0);
      final copy =
          (material as StandardMaterial).copyWith(roughness: .4)
              as PhysicalMaterial;
      expect(copy.clearcoatMap, same(map));
      expect(copy.clearcoatNormalScale, .5);
      expect(copy.specularColor.r, 2);
      expect(copy.ior, 0);
      mesh.material = copy.copyWith(clearClearcoatMap: true);
      final changed = capture();
      expect(changed.changedMeshes, 1);
      expect(changed.uploadedBytes, 0);
      encoder.accept(changed);
      mesh.material = copy;
      expect(capture().uploadedBytes, 4);
      final srgb = TextureMap(
        image: TextureImage.rgba(width: 1, height: 1, pixels: Uint8List(4)),
      );
      expect(() => PhysicalMaterial(clearcoatMap: srgb), throwsArgumentError);
      expect(
        () => PhysicalMaterial(clearcoatNormalScale: double.nan),
        throwsArgumentError,
      );
      expect(
        () => PhysicalMaterial(specularColor: const Color3(-1, 0, 0)),
        throwsArgumentError,
      );
    },
  );
}
