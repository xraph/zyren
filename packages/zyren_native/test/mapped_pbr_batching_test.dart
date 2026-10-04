import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'mapped PBR batches preserve tangents and mixed transform orientation',
    () async {
      final backend = await NativeBackend.create();
      TextureMap map(List<int> pixels, {bool srgb = false}) => TextureMap(
        image: TextureImage.rgba(
          width: 2,
          height: 2,
          pixels: Uint8List.fromList(pixels),
          format: srgb
              ? TextureFormat.rgba8UnormSrgb
              : TextureFormat.rgba8Unorm,
        ),
      );
      final plane = PlaneGeometry(width: .6, height: .8);
      final geometry = BufferGeometry.fromAttributes(
        attributes: {
          ...plane.attributes,
          VertexSemantic.tangent: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < 4; i++) ...[1, 0, 0, -1],
            ]),
            format: VertexFormat.float32x4,
          ),
        },
        indices: plane.indices,
      );
      final material = PhysicalMaterial(
        baseColor: const Color3(.8, .6, .4),
        metallic: .65,
        roughness: .45,
        baseColorMap: map([
          230,
          80,
          30,
          255,
          40,
          160,
          220,
          255,
          90,
          210,
          60,
          255,
          220,
          180,
          100,
          255,
        ], srgb: true),
        normalMap: map([
          180,
          150,
          230,
          255,
          100,
          185,
          230,
          255,
          150,
          80,
          230,
          255,
          80,
          120,
          230,
          255,
        ]),
        metallicRoughnessMap: map([
          0,
          160,
          230,
          255,
          0,
          230,
          180,
          255,
          0,
          180,
          200,
          255,
          0,
          200,
          150,
          255,
        ]),
      );
      final scene = Scene()
        ..background = const Color3(.02, .03, .04)
        ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
      scene.add(DirectionalLight(direction: const Vec3(-.4, -.3, -1)));
      final meshes = List.generate(4, (i) {
        final mesh = Mesh(geometry, material)
          ..position = Vec3((i - 1.5) * .9, 0, 0)
          ..scale = Vec3(i.isEven ? 1 : -1, .7 + i * .15, 1.3);
        scene.add(mesh);
        return mesh;
      });
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
      Future<ReadbackOutput> draw() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(241, 101),
                ),
              )
              as ReadbackOutput;
      try {
        final batched = await draw();
        expect(batched.stats.profile!.opaqueBatchDraws, greaterThan(0));
        expect(batched.stats.profile!.batchedSourceDraws, 4);
        for (var i = 0; i < meshes.length; i++) {
          meshes[i].renderOrder = i + 1;
        }
        final reference = await draw();
        expect(reference.stats.profile!.opaqueBatchDraws, 0);
        expect(reference.stats.profile!.executedMeshDraws, 4);
        expect(batched.image.pixels, orderedEquals(reference.image.pixels));
        final evidence = Platform.environment['ZYREN_QUALITY_EVIDENCE'];
        if (evidence != null) {
          File(
            '$evidence/mapped-batched.rgba',
          ).writeAsBytesSync(batched.image.pixels);
          File(
            '$evidence/mapped-reference.rgba',
          ).writeAsBytesSync(reference.image.pixels);
          File('$evidence/mapped-reference.json').writeAsStringSync(
            jsonEncode({
              'width': 241,
              'height': 101,
              'format': 'RGBA8',
              'batched': batched.stats.profile!.toJson(),
              'reference': reference.stats.profile!.toJson(),
            }),
          );
        }
        expect(
          batched.stats.admission!.presentedIdentities,
          reference.stats.admission!.presentedIdentities,
        );
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
