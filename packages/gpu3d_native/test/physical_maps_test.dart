import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import '../../gpu3d_gltf/test/support/pbr_fixture.dart';
import '../../gpu3d_gltf/test/support/fixtures.dart' show editModel;
import 'package:test/test.dart';
import 'support/environment_checks.dart'
    show constantEnvironment, smallEnvironment;

TextureMap dataMap(List<int> pixel, {bool srgb = false, int uvSet = 0}) =>
    TextureMap(
      image: TextureImage.rgba(
        width: 1,
        height: 1,
        pixels: Uint8List.fromList(pixel),
        format: srgb ? TextureFormat.rgba8UnormSrgb : TextureFormat.rgba8Unorm,
      ),
      uvSet: uvSet,
    );
double linear(int channel) {
  final c = channel / 255;
  return c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();
}

final class _Source implements ByteSourceResolver {
  final Uint8List bytes;
  _Source(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}

void main() {
  test(
    'glTF physical layers render through native HDR, MSAA and temporal AA',
    () async {
      final backend = await NativeBackend.create();
      final extensions = <String, Object?>{
        'KHR_materials_ior': {'ior': 1.8},
        'KHR_materials_specular': {'specularFactor': .6},
        'KHR_materials_clearcoat': {
          'clearcoatFactor': .7,
          'clearcoatRoughnessFactor': .4,
          'clearcoatNormalTexture': {'index': 2, 'scale': 0},
        },
        'KHR_materials_sheen': {
          'sheenColorFactor': [.2, .1, .3],
          'sheenRoughnessFactor': .5,
        },
        'KHR_materials_anisotropy': {
          'anisotropyStrength': .7,
          'anisotropyRotation': .4,
        },
        'KHR_materials_emissive_strength': {'emissiveStrength': 2},
      };
      final source = editModel(
        pbrModel(
          material: {
            'pbrMetallicRoughness': {
              'baseColorFactor': [.4, .6, .8, 1],
              'metallicFactor': 0,
              'roughnessFactor': .6,
            },
            'emissiveFactor': [.02, .01, .03],
            'extensions': extensions,
          },
        ),
        (root) {
          root['extensionsUsed'] = ['KHR_lights_punctual', ...extensions.keys];
          root['extensionsRequired'] = [
            'KHR_lights_punctual',
            ...extensions.keys,
          ];
          ((root['meshes'] as List).first['primitives'][0]['attributes'] as Map)
              .remove('TANGENT');
        },
      );
      final assets = AssetScope(
        services: AssetServices(
          resolver: _Source(source),
          imageDecoder: const NativeImageDecoder(),
          tangentGenerator: const NativeTangentGenerator(),
        ),
      );
      try {
        final model = await assets.load(Gltf.asset('physical.glb')).result;
        final scene = Scene()..add(model.instantiate());
        late Mesh mesh;
        void find(Object3D node) {
          if (node is Mesh) mesh = node;
          for (final child in node.children) {
            find(child);
          }
        }

        find(scene);
        expect(mesh.geometry.capture().tangents, isNotNull);
        final mapped = mesh.material;
        final reference = PhysicalMaterial(
          baseColor: const Color3(.4, .6, .8),
          roughness: .6,
          ior: 1.8,
          specularIntensity: .6,
          clearcoat: .7,
          clearcoatRoughness: .4,
          sheenColor: const Color3(.2, .1, .3),
          sheenRoughness: .5,
          anisotropy: .7,
          anisotropyRotation: .4,
          emissive: const Color3(.02, .01, .03),
          emissiveIntensity: 2,
        );
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
        for (final mode in ['hdr', 'msaa', 'taa']) {
          Future<List<int>> draw() async =>
              (await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(31, 31),
                          colorPipeline: ColorPipeline(
                            toneMapping: ToneMapping.linear,
                            sampleCount: mode == 'msaa' ? 4 : 1,
                          ),
                          temporalAA: mode == 'taa'
                              ? TemporalAAOptions()
                              : null,
                          temporalReset: 1,
                        ),
                      )
                      as ReadbackOutput)
                  .image
                  .pixels
                  .sublist(1920, 1924);
          mesh.material = mapped;
          final actual = await draw();
          mesh.material = reference;
          final expected = await draw();
          for (var channel = 0; channel < 4; channel++) {
            expect(
              actual[channel],
              closeTo(expected[channel], 1),
              reason: mode,
            );
          }
        }
      } on SceneException catch (error) {
        fail(error.issue.cause.toString());
      } finally {
        await assets.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'all physical map channels match factor-only lighting on native GPU',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      try {
        final environment = await EnvironmentMap.fromEquirectangular(
          constantEnvironment(1, .7, .4),
          resources: resources,
          quality: smallEnvironment,
        );
        final plane = PlaneGeometry(width: 4, height: 4);
        final geometry = BufferGeometry.fromAttributes(
          attributes: {
            ...plane.attributes,
            VertexSemantic.color: VertexAttribute(
              Float32List.fromList(List.filled(plane.vertexCount * 4, 1)),
              format: VertexFormat.float32x4,
            ),
            VertexSemantic.tangent: VertexAttribute(
              Float32List.fromList([
                for (var i = 0; i < plane.vertexCount; i++) ...[1, 0, 0, 1],
              ]),
              format: VertexFormat.float32x4,
            ),
          },
          indices: plane.indices,
          morphTargets: [
            MorphTarget(positions: List.filled(plane.vertexCount * 3, 0)),
          ],
        );
        final scalar = dataMap([64, 128, 192, 96]),
            color = dataMap([64, 128, 192, 255], srgb: true);
        final material = PhysicalMaterial(
          vertexColors: true,
          baseColor: const Color3(.4, .6, .8),
          roughness: .5,
          clearcoat: .8,
          clearcoatRoughness: .6,
          sheenColor: const Color3(.4, .2, .3),
          sheenRoughness: .7,
          specularIntensity: .75,
          specularColor: const Color3(.7, .8, .9),
          anisotropy: .8,
          anisotropyRotation: .3,
          clearcoatMap: scalar,
          clearcoatRoughnessMap: scalar,
          clearcoatNormalMap: dataMap([128, 128, 255, 255]),
          clearcoatNormalScale: 0,
          sheenColorMap: color,
          sheenRoughnessMap: scalar,
          specularIntensityMap: scalar,
          specularColorMap: color,
          anisotropyMap: scalar,
        );
        final reference = PhysicalMaterial(
          vertexColors: true,
          baseColor: material.baseColor,
          roughness: .5,
          clearcoat: .8 * 64 / 255,
          clearcoatRoughness: .6 * 128 / 255,
          sheenColor: Color3(
            .4 * linear(64),
            .2 * linear(128),
            .3 * linear(192),
          ),
          sheenRoughness: .7 * 96 / 255,
          specularIntensity: .75 * 96 / 255,
          specularColor: Color3(
            .7 * linear(64),
            .8 * linear(128),
            .9 * linear(192),
          ),
          anisotropy: .8 * 192 / 255,
          anisotropyRotation:
              .3 + math.atan2(128 * 2 / 255 - 1, 64 * 2 / 255 - 1),
        );
        for (final mode in [
          'directional',
          'area',
          'environment',
          'instances',
        ]) {
          final scene = Scene()..background = const Color3(0, 0, 0);
          if (mode == 'directional' || mode == 'instances') {
            scene.add(
              DirectionalLight(intensity: 2)..lookAt(const Vec3(-.7, 0, -1)),
            );
          }
          if (mode == 'area') {
            scene.add(
              RectAreaLight(width: 2, height: 1, intensity: 2)
                ..position = const Vec3(.5, 0, 2),
            );
          }
          final mesh = scene.add(
            mode == 'instances'
                ? InstancedMesh(geometry, material, count: 1)
                : Mesh(geometry, material),
          );
          mesh.setMorphWeight(0, .5);
          final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
          Future<ReadbackOutput> draw() async =>
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(31, 31),
                      environment: mode == 'environment'
                          ? Environment(map: environment)
                          : null,
                      colorPipeline: ColorPipeline(
                        toneMapping: ToneMapping.linear,
                      ),
                    ),
                  )
                  as ReadbackOutput;
          final actual = await draw();
          mesh.material = reference;
          final expected = await draw();
          for (var channel = 0; channel < 4; channel++) {
            expect(
              actual.image.pixels[1920 + channel],
              closeTo(expected.image.pixels[1920 + channel], 1),
              reason: '$mode channel=$channel',
            );
          }
          mesh.material = material.copyWith(
            clearClearcoatMap: true,
            clearSheenColorMap: true,
          );
          await draw();
          mesh.material = material;
          await draw();
          scene.remove(mesh);
          await draw();
        }
        await resources.close();
        expect((await backend.resourceStats()).residentBytes, 0);
      } on SceneException catch (error) {
        fail(error.issue.cause.toString());
      } finally {
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'clearcoat normal is independent from the base surface normal',
    () async {
      final backend = await NativeBackend.create();
      try {
        final plane = PlaneGeometry(width: 4, height: 4);
        final n = const Vec3(
          128 * 2 / 255 - 1,
          1 - 192 * 2 / 255,
          240 * 2 / 255 - 1,
        ).normalized();
        final geometry = BufferGeometry.fromAttributes(
          attributes: {
            ...plane.attributes,
            VertexSemantic.normal: VertexAttribute(
              Float32List.fromList([
                for (var i = 0; i < plane.vertexCount; i++) ...n.storage,
              ]),
              format: VertexFormat.float32x3,
            ),
          },
          indices: plane.indices,
        );
        final scene = Scene()
          ..add(DirectionalLight(intensity: 3)..lookAt(const Vec3(0, -1, -1)));
        final coat = PhysicalMaterial(
          baseColor: const Color3(0, 0, 0),
          specularIntensity: 0,
          clearcoat: 1,
          clearcoatRoughness: .7,
        );
        final mesh = scene.add(
          Mesh(
            plane,
            coat.copyWith(clearcoatNormalMap: dataMap([128, 192, 240, 255])),
          ),
        );
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
        Future<List<int>> draw() async =>
            (await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(31, 31),
                      ),
                    )
                    as ReadbackOutput)
                .image
                .pixels
                .sublist(1920, 1924);
        final actual = await draw();
        scene.remove(mesh);
        scene.add(Mesh(geometry, coat));
        final expected = await draw();
        for (var c = 0; c < 3; c++) {
          expect(actual[c], closeTo(expected[c], 1));
        }
        expect(actual[0], greaterThan(5));
      } on SceneException catch (error) {
        fail(error.issue.cause.toString());
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
