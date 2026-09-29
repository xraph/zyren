import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

BufferGeometry _geometry({
  List<double> positions = const [-2, -2, 0, 2, -2, 0, 0, 2, 0],
  List<double> colors = const [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1],
  GeometryTopology topology = GeometryTopology.triangles,
  bool maps = false,
}) => BufferGeometry.fromAttributes(
  attributes: {
    VertexSemantic.position: VertexAttribute(
      Float32List.fromList(positions),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.normal: VertexAttribute(
      Float32List.fromList([
        for (var i = 0; i < positions.length ~/ 3; i++) ...[0, 0, 1],
      ]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.color: VertexAttribute(
      Uint8List.fromList([for (final value in colors) (value * 255).round()]),
      format: VertexFormat.unorm8x4,
    ),
    if (maps)
      VertexSemantic.uv0: VertexAttribute(
        Float32List(positions.length ~/ 3 * 2),
        format: VertexFormat.float32x2,
      ),
    if (maps)
      VertexSemantic.tangent: VertexAttribute(
        Float32List.fromList([
          for (var i = 0; i < positions.length ~/ 3; i++) ...[1, 0, 0, 1],
        ]),
        format: VertexFormat.float32x4,
      ),
  },
  indices: List.generate(positions.length ~/ 3, (i) => i),
  topology: topology,
  dynamic: true,
);
TextureMap _map(List<int> pixel) => TextureMap(
  image: TextureImage.rgba(
    width: 1,
    height: 1,
    pixels: Uint8List.fromList(pixel),
    format: TextureFormat.rgba8Unorm,
  ),
);
int _srgb(double v) =>
    ((v <= .0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - .055) * 255)
        .round();

Future<void> verifyVertexColors(NativeGpuBackend backend) async {
  var scene = Scene()..background = const Color3(0, 0, 0);
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
  ColorPipeline? pipeline;
  FrameSubmission capture() => FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(31, 31),
    colorPipeline: pipeline,
  );
  Future<ReadbackOutput> draw() async =>
      await backend.render(capture()) as ReadbackOutput;
  List<int> center(ReadbackOutput output) =>
      output.image.pixels.sublist(1920, 1924);
  void pixel(ReadbackOutput output, List<int> expected, String reason) {
    final actual = center(output);
    for (var i = 0; i < 4; i++) {
      expect(
        actual[i],
        closeTo(expected[i], 2),
        reason: '$reason: $actual vs $expected',
      );
    }
  }

  final geometry = _geometry();
  var mesh = scene.add(Mesh(geometry, UnlitMaterial(vertexColors: true)));
  final initial = await draw();
  pixel(initial, [137, 137, 188, 255], 'linear barycentric colors');
  mesh.material = UnlitMaterial(color: const Color3(1, 1, 1));
  pixel(await draw(), [255, 255, 255, 255], 'material opt-in');
  mesh.material = UnlitMaterial(vertexColors: true);
  final frozen = capture();
  final peer = backend is NativeBackend ? backend.createView() : null;
  try {
    if (peer != null) {
      pixel(
        await peer.render(frozen) as ReadbackOutput,
        center(initial),
        'peer baseline',
      );
    }
    geometry.updateAttribute(
      VertexSemantic.color,
      Uint8List.fromList([255, 0, 0, 255]),
      firstVertex: 2,
    );
    final changed = await draw();
    expect(changed.stats.uploadedBytes, 16);
    pixel(changed, [_srgb(.75), _srgb(.25), 0, 255], 'one-vertex color delta');
    if (peer != null) {
      pixel(
        await peer.render(frozen) as ReadbackOutput,
        center(initial),
        'peer keeps old GPU colors',
      );
    }
  } finally {
    await peer?.close();
  }

  scene.remove(mesh);
  final solid = _geometry(
    maps: true,
    colors: [
      for (var i = 0; i < 3; i++) ...[1, 0, 0, 128 / 255],
    ],
  );
  mesh = scene.add(Mesh(solid, UnlitMaterial(vertexColors: true)));
  pixel(await draw(), [255, 0, 0, 255], 'opaque ignores vertex alpha');
  mesh.material = UnlitMaterial(
    vertexColors: true,
    alphaMode: MaterialAlphaMode.mask,
    alphaCutoff: .6,
  );
  pixel(await draw(), [0, 0, 0, 255], 'vertex mask');
  mesh.material = UnlitMaterial(
    vertexColors: true,
    alphaMode: MaterialAlphaMode.blend,
    opacity: .5,
  );
  pixel(await draw(), [
    _srgb(128 / 255 * .5),
    0,
    0,
    255,
  ], 'vertex alpha times opacity');
  mesh.material = UnlitMaterial(
    vertexColors: true,
    colorMap: _map([128, 255, 255, 128]),
    alphaMode: MaterialAlphaMode.mask,
    alphaCutoff: .3,
  );
  pixel(await draw(), [0, 0, 0, 255], 'map alpha times vertex alpha');
  mesh.material = UnlitMaterial(
    vertexColors: true,
    colorMap: _map([128, 255, 255, 128]),
    alphaMode: MaterialAlphaMode.mask,
    alphaCutoff: .2,
  );
  pixel(await draw(), [
    _srgb(128 / 255),
    0,
    0,
    255,
  ], 'map color times vertex color');
  mesh.material = DiffuseMaterial(vertexColors: true);
  scene.ambient = 1;
  pixel(await draw(), [255, 0, 0, 255], 'diffuse color');

  mesh.material = StandardMaterial(
    vertexColors: true,
    emissive: const Color3(0, .25, .5),
  );
  pixel(await draw(), [0, 137, 188, 255], 'emission is not tinted');
  final sun = scene.add(DirectionalLight());
  mesh.material = StandardMaterial(vertexColors: true);
  final pbr = [
    _srgb(.96 / math.pi + .04 / (4 * math.pi)),
    _srgb(.04 / (4 * math.pi)),
    _srgb(.04 / (4 * math.pi)),
    255,
  ];
  pixel(await draw(), pbr, 'PBR base color and dielectric specular');
  mesh.material = StandardMaterial(
    vertexColors: true,
    normalMap: _map([128, 128, 255, 255]),
    metallicRoughnessMap: _map([255, 255, 0, 255]),
    baseColorMap: _map([255, 255, 255, 255]),
  );
  pixel(await draw(), pbr, 'UV tangent and color buffers bind together');
  pipeline = ColorPipeline(toneMapping: ToneMapping.linear);
  pixel(await draw(), pbr, 'HDR color packet');
  pipeline = null;
  scene.remove(sun);
  scene.remove(mesh);

  mesh = scene.add(
    Mesh(
      _geometry(
        topology: GeometryTopology.points,
        positions: [0, 0, 0],
        colors: [0, 1, 0, 1],
      ),
      PointsMaterial(vertexColors: true, size: 9),
    ),
  );
  pixel(await draw(), [0, 255, 0, 255], 'colored point');
  scene.remove(mesh);
  mesh = scene.add(
    Mesh(
      _geometry(
        topology: GeometryTopology.lineSegments,
        positions: [-1, 0, 0, 1, 0, 0],
        colors: [1, 0, 0, 1, 0, 0, 1, 1],
      ),
      LineMaterial(vertexColors: true, width: 5),
    ),
  );
  pixel(await draw(), [188, 0, 188, 255], 'colored line midpoint');
  scene.remove(mesh);
  // The segment crosses the camera plane. Its visible midpoint is t=.5 in
  // world space, even after clipping changes the projected first endpoint.
  mesh = scene.add(
    Mesh(
      _geometry(
        topology: GeometryTopology.lineSegments,
        positions: [-1, 0, 3, 1, 0, -1],
        colors: [1, 0, 0, 1, 0, 0, 1, 1],
      ),
      LineMaterial(vertexColors: true, width: 5),
    ),
  );
  pixel(await draw(), [188, 0, 188, 255], 'clipping preserves endpoint colors');
  scene = Scene();
  await draw();
  expect((await backend.resourceStats()).residentBytes, 0);
  await _shadows(backend);
}

Future<void> _shadows(NativeGpuBackend backend) async {
  final source = BoxGeometry(width: .5, height: .5, depth: .5);
  final geometry = BufferGeometry.fromAttributes(
    attributes: {
      ...source.attributes,
      VertexSemantic.color: VertexAttribute(
        Uint8List.fromList([
          for (var i = 0; i < source.vertexCount; i++) ...[255, 255, 255, 0],
        ]),
        format: VertexFormat.unorm8x4,
      ),
    },
    indices: source.indices,
    dynamic: true,
  );
  final scene = Scene()..background = const Color3(0, 0, 0);
  scene.add(
    Mesh(PlaneGeometry(width: 5, height: 5), StandardMaterial())
      ..receiveShadow = true,
  );
  final caster = scene.add(
    Mesh(
        geometry,
        UnlitMaterial(vertexColors: true, alphaMode: MaterialAlphaMode.mask),
      )
      ..position = const Vec3(0, 0, 1)
      ..castShadow = true,
  );
  scene.add(
    DirectionalLight(
      shadow: DirectionalShadow(cascades: 1, distance: 10, normalBias: 0),
    )..lookAt(const Vec3(.6, 0, -.8)),
  );
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
  Future<int> probe() async {
    final output =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(31, 31),
              ),
            )
            as ReadbackOutput;
    return output.image.pixels[(15 * 31 + 20) * 4];
  }

  final lit = await probe();
  expect(
    lit,
    greaterThan(100),
    reason: 'zero vertex alpha leaves receiver lit',
  );
  geometry.updateAttribute(
    VertexSemantic.color,
    Uint8List.fromList([
      for (var i = 0; i < geometry.vertexCount; i++) ...[255, 255, 255, 128],
    ]),
  );
  expect(
    await probe(),
    lessThan(5),
    reason: 'color delta invalidates shadow atlas',
  );
  caster.material = UnlitMaterial(
    vertexColors: true,
    alphaMode: MaterialAlphaMode.mask,
    colorMap: _map([255, 255, 255, 128]),
  );
  expect(
    await probe(),
    closeTo(lit, 1),
    reason: 'shadow combines texture and vertex alpha',
  );
  caster.material = UnlitMaterial(
    vertexColors: false,
    alphaMode: MaterialAlphaMode.mask,
    colorMap: _map([255, 255, 255, 128]),
  );
  expect(
    await probe(),
    lessThan(5),
    reason: 'vertex flag invalidates masked shadow',
  );
  caster.material = UnlitMaterial(
    vertexColors: true,
    alphaMode: MaterialAlphaMode.opaque,
    opacity: 0,
  );
  expect(await probe(), lessThan(5), reason: 'opaque shadow ignores alpha');
  await backend.render(
    FrameSubmission.capture(
      scene: Scene(),
      camera: camera,
      size: PhysicalSize(31, 31),
    ),
  );
  expect((await backend.resourceStats()).residentBytes, 0);
}
