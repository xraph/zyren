import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'deformation_checks.dart' show skinBox, deformedReference;

MeshMaterial tinted(MeshMaterial material, Color3 tint) {
  final c = material.color;
  final color = Color3(c.r * tint.r, c.g * tint.g, c.b * tint.b);
  return switch (material) {
    UnlitMaterial() => material.copyWith(color: color),
    DiffuseMaterial() => material.copyWith(color: color),
    StandardMaterial() => material.copyWith(baseColor: color),
    _ => throw ArgumentError('Expected a built-in triangle material.'),
  };
}

Future<void> verifyInstanceColors(NativeGpuBackend backend) async {
  final box = skinBox();
  final geometry = BufferGeometry.fromData(
    await const NativeTangentGenerator().generate(
      GeometryData(
        attributes: box.attributes,
        indices: box.indices,
        morphTargets: box.morphTargets,
      ),
    ),
  );
  final rigid = BufferGeometry.fromAttributes(
    attributes: geometry.attributes,
    indices: geometry.indices,
  );
  final colorMap = TextureMap(
    image: TextureImage.rgba(
      width: 1,
      height: 1,
      pixels: Uint8List.fromList([180, 220, 150, 210]),
    ),
  );
  final normalMap = TextureMap(
    image: TextureImage.rgba(
      width: 1,
      height: 1,
      pixels: Uint8List.fromList([170, 150, 235, 255]),
      format: TextureFormat.rgba8Unorm,
    ),
  );
  final materials = <MeshMaterial>[
    UnlitMaterial(),
    UnlitMaterial(vertexColors: true),
    UnlitMaterial(colorMap: colorMap),
    UnlitMaterial(colorMap: colorMap, vertexColors: true),
    DiffuseMaterial(color: const Color3(.8, .7, .9)),
    StandardMaterial(roughness: .7),
    StandardMaterial(roughness: .7, vertexColors: true),
    StandardMaterial(baseColorMap: colorMap, normalMap: normalMap),
    StandardMaterial(
      baseColorMap: colorMap,
      normalMap: normalMap,
      vertexColors: true,
    ),
    UnlitMaterial(
      colorMap: colorMap,
      vertexColors: true,
      alphaMode: MaterialAlphaMode.mask,
      alphaCutoff: .2,
    ),
    UnlitMaterial(
      colorMap: colorMap,
      vertexColors: true,
      alphaMode: MaterialAlphaMode.blend,
      opacity: .6,
    ),
  ];
  const colors = [Color3(.15, .7, 1), Color3(1, .25, .1)];
  final positions = [const Vec3(-.6, 0, 0), const Vec3(.6, 0, .1)];
  final scales = [const Vec3(-.6, .8, 1), const Vec3(.6, 1.1, .7)];
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  Future<ReadbackOutput> draw(Scene scene) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(83, 83),
            ),
          )
          as ReadbackOutput;
  for (final deformed in [false, true]) {
    for (final material in materials) {
      final scene = Scene()..background = const Color3(0, 0, 0);
      final expected = Scene()..background = const Color3(0, 0, 0);
      for (final s in [scene, expected]) {
        s.add(DirectionalLight()..lookAt(const Vec3(-.3, -.2, -1)));
      }
      final mesh = scene.add(
        InstancedMesh(deformed ? geometry : rigid, material, count: 2)
          ..setColors(0, colors)
          ..setTransforms(0, [
            for (var i = 0; i < 2; i++)
              Mat4.compose(positions[i], Quat.identity, scales[i]),
          ])
          ..scale = const Vec3(-1, 1.1, .8),
      );
      if (deformed) mesh.setMorphWeight(0, .6);
      final referenceGeometry = deformed ? deformedReference(mesh) : rigid;
      final group = expected.add(Group()..scale = mesh.scale);
      for (var i = 0; i < 2; i++) {
        group.add(
          Mesh(referenceGeometry, tinted(material, colors[i]))
            ..position = positions[i]
            ..scale = scales[i],
        );
      }
      final actual = await draw(scene), reference = await draw(expected);
      var difference = 0, visible = 0;
      for (var i = 0; i < actual.image.pixels.length; i++) {
        difference = math.max(
          difference,
          (actual.image.pixels[i] - reference.image.pixels[i]).abs(),
        );
        if (i % 4 != 3 && actual.image.pixels[i] > 10) visible++;
      }
      expect(visible, greaterThan(100));
      expect(
        difference,
        lessThanOrEqualTo(3),
        reason:
            '${material.runtimeType}, deformed $deformed, colors ${material.vertexColors}, ${material.alphaMode}',
      );
      expect(
        actual.stats.drawCalls,
        material.alphaMode == MaterialAlphaMode.blend ? 2 : 1,
      );
    }
  }

  final mesh = InstancedMesh(PlaneGeometry(), UnlitMaterial(), count: 2)
    ..setTransforms(0, [
      for (final position in positions)
        Mat4.compose(position, Quat.identity, const Vec3(.6, .8, 1)),
    ]);
  final scene = Scene()..add(mesh);
  FrameSubmission capture() => FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(83, 83),
  );
  final frozen = capture();
  final original = await backend.render(frozen) as ReadbackOutput;
  mesh.setColor(1, colors[1]);
  final changed = await draw(scene);
  expect(changed.stats.uploadedBytes, 128);
  expect(changed.image.pixels, isNot(orderedEquals(original.image.pixels)));
  expect(
    (await backend.render(frozen) as ReadbackOutput).image.pixels,
    orderedEquals(original.image.pixels),
  );
}
