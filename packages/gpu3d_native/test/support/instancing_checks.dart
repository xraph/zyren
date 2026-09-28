import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

Future<void> verifyInstancing(NativeGpuBackend backend) async {
  final scene = Scene()..background = const Color3(0, 0, 0);
  final geometry = BoxGeometry(width: .3, height: .3, depth: .3);
  final mesh = scene.add(
    InstancedMesh(
      geometry,
      UnlitMaterial(color: const Color3(1, 0, 0)),
      count: 10000,
    ),
  );
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  FrameSubmission capture() => FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(81, 81),
  );
  Future<ReadbackOutput> render(FrameSubmission f) async =>
      await backend.render(f) as ReadbackOutput;
  mesh.setTransforms(
    0,
    List.generate(
      10000,
      (i) => Mat4.compose(
        Vec3((i % 100) * .04 - 2, (i ~/ 100) * .04 - 2, 0),
        Quat.identity,
        const Vec3(.1, .1, .1),
      ),
    ),
  );
  final first = await render(capture());
  expect(first.stats.drawCalls, 1);
  expect(first.stats.triangles, 120000);
  expect(first.stats.uploadedBytes, greaterThanOrEqualTo(1120000));
  expect(first.image.pixels.where((v) => v > 200).length, greaterThan(81 * 81));
  mesh.setTransform(
    42,
    Mat4.compose(const Vec3(5, 0, 0), Quat.identity, Vec3.one),
  );
  final updated = await render(capture());
  expect(updated.stats.uploadedBytes, 112);
  mesh.count = 2;
  mesh.setTransforms(0, [
    Mat4.compose(const Vec3(-.6, 0, 0), Quat.identity, Vec3.one),
    Mat4.compose(const Vec3(.6, 0, 0), Quat.identity, const Vec3(-1, 1, 1)),
  ]);
  final frozen = capture();
  final pair = await render(frozen);
  expect(pair.stats.uploadedBytes, 224);
  expect(pair.stats.drawCalls, 1);
  mesh.position = const Vec3(0, .3, 0);
  final parent = await render(capture());
  expect(parent.stats.uploadedBytes, 0);
  expect(parent.image.pixels, isNot(orderedEquals(pair.image.pixels)));
  final old = await render(frozen);
  expect(old.image.pixels, orderedEquals(pair.image.pixels));
  mesh.position = Vec3.zero;
  mesh.visible = false;
  mesh.setTransform(
    1,
    Mat4.compose(const Vec3(.6, .6, 0), Quat.identity, Vec3.one),
  );
  expect((await render(capture())).stats.uploadedBytes, 0);
  mesh.visible = true;
  expect((await render(capture())).stats.uploadedBytes, 112);
  expect((await render(frozen)).image.pixels, orderedEquals(pair.image.pixels));
}

Future<void> verifyInstanceMaterials(NativeGpuBackend backend) async {
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  Future<ReadbackOutput> draw(Scene s) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: s,
              camera: camera,
              size: PhysicalSize(81, 81),
            ),
          )
          as ReadbackOutput;
  final image = TextureImage.rgba(
    width: 1,
    height: 1,
    pixels: Uint8List.fromList([160, 100, 250, 180]),
  );
  final normal = TextureImage.rgba(
    width: 1,
    height: 1,
    pixels: Uint8List.fromList([180, 155, 230, 255]),
    format: TextureFormat.rgba8Unorm,
  );
  final geometry = BoxGeometry(width: .7, height: .7, depth: .7);
  final tangents = await const NativeTangentGenerator().generate(
    GeometryData(attributes: geometry.attributes, indices: geometry.indices),
  );
  final colored = BufferGeometry.fromAttributes(
    attributes: {
      ...tangents.attributes,
      VertexSemantic.color: VertexAttribute(
        Float32List.fromList([
          for (var i = 0; i < tangents.layout.vertexCount; i++) ...[
            .6,
            .8,
            .4,
            .7,
          ],
        ]),
        format: VertexFormat.float32x4,
      ),
    },
    indices: tangents.indices,
  );
  final transforms = [
    Mat4.compose(
      const Vec3(-.5, 0, 0),
      Quat.axisAngle(const Vec3(0, 1, 0), .4),
      const Vec3(-1, .7, 1.3),
    ),
    Mat4.compose(
      const Vec3(.5, 0, .4),
      Quat.axisAngle(const Vec3(0, 1, 0), -.5),
      const Vec3(1.1, 1.3, .6),
    ),
  ];
  for (final material in <MeshMaterial>[
    UnlitMaterial(
      colorMap: TextureMap(image: image),
      side: MaterialSide.front,
    ),
    DiffuseMaterial(color: const Color3(.6, .8, .9), side: MaterialSide.front),
    StandardMaterial(
      vertexColors: true,
      baseColorMap: TextureMap(image: image),
      normalMap: TextureMap(image: normal),
      roughness: .7,
      side: MaterialSide.front,
    ),
    UnlitMaterial(
      colorMap: TextureMap(image: image),
      alphaMode: MaterialAlphaMode.mask,
      alphaCutoff: .8,
      side: MaterialSide.front,
    ),
    UnlitMaterial(
      colorMap: TextureMap(image: image),
      alphaMode: MaterialAlphaMode.blend,
      opacity: .5,
    ),
  ]) {
    final activeGeometry = material.vertexColors ? colored : geometry;
    final instanced = Scene()..background = const Color3(0, 0, 0);
    final ordinary = Scene()..background = const Color3(0, 0, 0);
    for (final scene in [instanced, ordinary]) {
      scene.add(DirectionalLight()..lookAt(const Vec3(-.3, -.2, -1)));
    }
    final mesh = instanced.add(
      InstancedMesh(activeGeometry, material, count: 2),
    );
    mesh.setTransforms(0, transforms);
    for (var i = 0; i < 2; i++) {
      final part = ordinary.add(Mesh(activeGeometry, material));
      part.position = i == 0 ? const Vec3(-.5, 0, 0) : const Vec3(.5, 0, .4);
      part.quaternion = Quat.axisAngle(const Vec3(0, 1, 0), i == 0 ? .4 : -.5);
      part.scale = i == 0 ? const Vec3(-1, .7, 1.3) : const Vec3(1.1, 1.3, .6);
    }
    final batched = await draw(instanced), reference = await draw(ordinary);
    final a = batched.image.pixels, b = reference.image.pixels;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference = math.max(difference, (a[i] - b[i]).abs());
    }
    expect(
      difference,
      lessThanOrEqualTo(2),
      reason: '${material.runtimeType} ${material.alphaMode}',
    );
    expect(
      batched.stats.drawCalls,
      material.alphaMode == MaterialAlphaMode.blend ? 2 : 1,
    );
  }
}

Future<void> verifyInstanceShadows(NativeGpuBackend backend) async {
  final scene = Scene()..background = const Color3(0, 0, 0);
  scene.add(
    Mesh(PlaneGeometry(width: 5, height: 5), StandardMaterial(roughness: 1))
      ..receiveShadow = true,
  );
  final caster = scene.add(
    InstancedMesh(
      BoxGeometry(width: .5, height: .5, depth: .5),
      UnlitMaterial(side: MaterialSide.front),
      count: 2,
    )..castShadow = true,
  );
  caster.setTransforms(0, [
    Mat4.compose(const Vec3(0, 0, 1), Quat.identity, const Vec3(-1, 1, 1)),
    Mat4.compose(const Vec3(-2, 0, 1), Quat.identity, Vec3.one),
  ]);
  scene.add(
    DirectionalLight(
      shadow: DirectionalShadow(cascades: 2, distance: 10, normalBias: 0),
    )..lookAt(const Vec3(.6, 0, -.8)),
  );
  Future<int> probe() async {
    final output =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(position: const Vec3(0, 0, 5)),
                size: PhysicalSize(31, 31),
              ),
            )
            as ReadbackOutput;
    return output.image.pixels[(15 * 31 + 20) * 4];
  }

  expect(await probe(), lessThan(5));
  final stats = await backend.shadowStats();
  await probe();
  expect((await backend.shadowStats()).renderedViews, stats.renderedViews);
  caster.setTransform(
    0,
    Mat4.compose(const Vec3(-2, 0, 1), Quat.identity, Vec3.one),
  );
  expect(await probe(), greaterThan(100));
  expect((await backend.shadowStats()).renderedViews, stats.renderedViews + 2);
}

Future<void> verifyInstanceBlendOrder(NativeGpuBackend backend) async {
  final red = UnlitMaterial(
    color: const Color3(1, 0, 0),
    alphaMode: MaterialAlphaMode.blend,
    opacity: .5,
  );
  final blue = UnlitMaterial(
    color: const Color3(0, 0, 1),
    alphaMode: MaterialAlphaMode.blend,
    opacity: .5,
  );
  final geometry = PlaneGeometry(width: 2, height: 2);
  final scene = Scene()..background = const Color3(0, 0, 0);
  final reference = Scene()..background = const Color3(0, 0, 0);
  final instances = scene.add(InstancedMesh(geometry, red, count: 2));
  instances.setTransforms(0, [
    Mat4.compose(const Vec3(0, 0, .7), Quat.identity, Vec3.one),
    Mat4.compose(const Vec3(0, 0, -.7), Quat.identity, Vec3.one),
  ]);
  scene.add(Mesh(geometry, blue));
  reference.add(Mesh(geometry, red)..position = const Vec3(0, 0, .7));
  reference.add(Mesh(geometry, red)..position = const Vec3(0, 0, -.7));
  reference.add(Mesh(geometry, blue));
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  Future<ReadbackOutput> draw(Scene scene) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(41, 41),
            ),
          )
          as ReadbackOutput;
  for (final z in [4.0, -4.0]) {
    camera.position = Vec3(0, 0, z);
    final actual = await draw(scene);
    final expected = await draw(reference);
    expect(actual.image.pixels, orderedEquals(expected.image.pixels));
    expect(actual.stats.drawCalls, 3);
    final offset = (20 * 41 + 20) * 4;
    expect(
      actual.image.pixels[offset],
      greaterThan(actual.image.pixels[offset + 2]),
    );
  }
}
