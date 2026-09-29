import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
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
}
