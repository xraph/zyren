import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

BufferGeometry _geometry({bool tangent = false}) =>
    BufferGeometry.fromAttributes(
      attributes: {
        VertexSemantic.position: VertexAttribute(
          Float32List.fromList([-2, -2, 0, 2, -2, 0, 0, 2, 0]),
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.normal: VertexAttribute(
          Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.uv0: VertexAttribute(
          Float32List.fromList([0, 0, 1, 0, .5, 1]),
          format: VertexFormat.float32x2,
        ),
        VertexSemantic.uv1: VertexAttribute(
          Float32List.fromList([.75, .5, .75, .5, .75, .5]),
          format: VertexFormat.float32x2,
        ),
        if (tangent)
          VertexSemantic.tangent: VertexAttribute(
            Float32List.fromList([1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1]),
            format: VertexFormat.float32x4,
          ),
      },
      indices: [0, 1, 2],
      dynamic: true,
    );
TextureMap _map(List<int> bytes, {bool srgb = false, int uvSet = 0}) =>
    TextureMap(
      image: TextureImage.rgba(
        width: bytes.length ~/ 4,
        height: 1,
        pixels: Uint8List.fromList(bytes),
        format: srgb ? TextureFormat.rgba8UnormSrgb : TextureFormat.rgba8Unorm,
      ),
      sampler: const SamplerDescriptor(
        minFilter: TextureFilter.nearest,
        magFilter: TextureFilter.nearest,
      ),
      uvSet: uvSet,
    );

Future<void> verifyStandardMaps(NativeGpuBackend backend) async {
  final scene = Scene()..background = const Color3(0, 0, 0);
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
  final emission = _map([64, 0, 0, 255, 0, 128, 0, 255], srgb: true, uvSet: 1);
  final initialGeometry = _geometry()
    ..updateAttribute(
      VertexSemantic.uv0,
      Float32List.fromList([.25, .5, .25, .5, .25, .5]),
    );
  var mesh = scene.add(
    Mesh(
      initialGeometry,
      StandardMaterial(emissive: const Color3(1, 1, 1), emissiveMap: emission),
    ),
  );
  Future<ReadbackOutput> draw() async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(31, 31),
            ),
          )
          as ReadbackOutput;
  List<int> center(ReadbackOutput output) =>
      output.image.pixels.sublist(1920, 1924);
  void pixel(ReadbackOutput frame, List<int> expected) {
    final actual = center(frame);
    for (var i = 0; i < 4; i++) {
      expect(
        actual[i],
        closeTo(expected[i], 2),
        reason: '$actual vs $expected',
      );
    }
  }

  pixel(await draw(), [0, 128, 0, 255]);
  mesh.material = (mesh.material as StandardMaterial).copyWith(
    emissiveMap: TextureMap(
      image: emission.image,
      uvSet: 0,
      sampler: const SamplerDescriptor(
        wrapU: TextureWrap.repeat,
        minFilter: TextureFilter.nearest,
        magFilter: TextureFilter.nearest,
      ),
    ),
  );
  final changedMap = await draw();
  pixel(changedMap, [64, 0, 0, 255]);
  expect(changedMap.stats.uploadedBytes, 0);
  final sun = scene.add(DirectionalLight());
  final packed = _map([0, 255, 255, 255]);
  mesh.material = StandardMaterial(
    baseColor: const Color3(.5, .5, .5),
    metallic: 1,
    metallicRoughnessMap: packed,
    occlusionMap: packed,
  );
  pixel(await draw(), [56, 56, 56, 255]);
  mesh.material = (mesh.material as StandardMaterial).copyWith(metallic: 0);
  pixel(await draw(), [110, 110, 110, 255]);
  sun.visible = false;
  final hemisphere = scene.add(
    HemisphereLight(groundColor: const Color3(1, 1, 1)),
  );
  pixel(await draw(), [0, 0, 0, 255]);
  mesh.material = (mesh.material as StandardMaterial).copyWith(
    occlusionStrength: 0,
  );
  pixel(await draw(), [109, 109, 109, 255]);
  mesh.material = (mesh.material as StandardMaterial).copyWith(
    occlusionStrength: 1,
    emissive: const Color3(.25, .25, .25),
  );
  pixel(await draw(), [137, 137, 137, 255]);
  hemisphere.visible = false;
  sun.visible = true;
  sun.lookAt(const Vec3(0, -.6, -.8));
  final normalMap = _map([128, 204, 230, 255]);
  final normalMaterial = StandardMaterial(
    baseColor: const Color3(.5, .5, .5),
    normalMap: normalMap,
  );
  scene.remove(mesh);
  final geometry = _geometry(tangent: true);
  mesh = scene.add(Mesh(geometry, normalMaterial));
  final explicit = await draw();
  scene.remove(mesh);
  mesh = scene.add(Mesh(_geometry(), normalMaterial));
  pixel(await draw(), center(explicit));
  final uv1Geometry = _geometry();
  uv1Geometry.updateAttribute(
    VertexSemantic.uv1,
    Float32List.fromList(uv1Geometry.uv0!),
  );
  uv1Geometry.updateAttribute(
    VertexSemantic.uv0,
    Float32List.fromList([0, 0, 0, 0, 0, 0]),
  );
  scene.remove(mesh);
  mesh = scene.add(
    Mesh(
      uv1Geometry,
      normalMaterial.copyWith(
        normalMap: TextureMap(image: normalMap.image, uvSet: 1),
      ),
    ),
  );
  pixel(await draw(), center(explicit));
  scene.remove(mesh);
  mesh = scene.add(Mesh(geometry, normalMaterial));
  await draw();
  final peer = backend is NativeBackend ? backend.createView() : null;
  final frozen = FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(31, 31),
  );
  try {
    if (peer != null) {
      pixel(await peer.render(frozen) as ReadbackOutput, center(explicit));
    }
    geometry.updateAttribute(
      VertexSemantic.tangent,
      Float32List.fromList([1, 0, 0, -1, 1, 0, 0, -1, 1, 0, 0, -1]),
    );
    final flipped = await draw();
    expect(flipped.stats.uploadedBytes, 48);
    expect(center(flipped)[0], lessThan(center(explicit)[0] - 10));
    if (peer != null) {
      pixel(await peer.render(frozen) as ReadbackOutput, center(explicit));
    }
  } finally {
    await peer?.close();
  }
  mesh.material = normalMaterial.copyWith(normalScale: 0);
  final flattened = await draw();
  mesh.material = normalMaterial.copyWith(clearNormalMap: true);
  pixel(await draw(), center(flattened));
  scene.remove(mesh);
  await draw();
  expect((await backend.resourceStats()).residentBytes, 0);
}
