import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_native/zyren_native.dart';
import '../../zyren_gltf/test/support/fixtures.dart';

class Source implements ByteSourceResolver {
  final Uint8List bytes;
  Source(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}

void main() {
  test(
    'loaded standard glTF and each punctual light match ordinary native scene objects',
    () async {
      final backend = await NativeBackend.create();
      final camera = OrthographicCamera(
        left: -1,
        right: 1,
        top: 1,
        bottom: -1,
        near: .1,
        far: 10,
        position: const Vec3(0, 0, 3),
      );
      Future<Uint8List> render(Scene scene) async =>
          (await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(33, 33),
                    ),
                  )
                  as ReadbackOutput)
              .image
              .pixels;
      try {
        final manual = Scene()
          ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
        manual.add(
          Mesh(
            PlaneGeometry(width: 2, height: 2),
            StandardMaterial(
              baseColor: const Color3(.5, .2, .1),
              metallic: 0,
              roughness: .5,
              side: MaterialSide.front,
            ),
          ),
        );
        manual.add(DirectionalLight());
        final reference = await render(manual), center = (16 * 33 + 16) * 4;
        for (final type in ['directional', 'point', 'spot']) {
          final bytes = primitiveModel(
            indices: [0, 1, 2, 0, 2, 3],
            normals: [
              for (var i = 0; i < 4; i++) ...[0.0, 0.0, 1.0],
            ],
            tangents: [
              for (var i = 0; i < 4; i++) ...[1.0, 0.0, 0.0, 1.0],
            ],
            changes: {
              'extensionsUsed': ['KHR_lights_punctual'],
              'extensionsRequired': ['KHR_lights_punctual'],
              'materials': [
                {
                  'pbrMetallicRoughness': {
                    'baseColorFactor': [.5, .2, .1, 1],
                    'metallicFactor': 0,
                    'roughnessFactor': .5,
                  },
                },
              ],
              'extensions': {
                'KHR_lights_punctual': {
                  'lights': [
                    {
                      'type': type,
                      'intensity': type == 'directional' ? 1 : 4,
                      if (type == 'spot') 'spot': <String, Object?>{},
                    },
                  ],
                },
              },
              'nodes': [
                {'mesh': 0},
                {
                  'translation': [0, 0, 2],
                  'extensions': {
                    'KHR_lights_punctual': {'light': 0},
                  },
                },
              ],
              'scenes': [
                {
                  'nodes': [0, 1],
                },
              ],
            },
          );
          final assets = AssetScope(
            services: AssetServices(resolver: Source(bytes)),
          );
          try {
            final model = await assets.load(Gltf.asset('$type.glb')).result;
            final scene = Scene()
              ..renderSettings = RenderSettings(
                toneMapping: ToneMapping.reinhard,
              );
            final group = scene.add(model.instantiate());
            final pixel = (await render(scene)).sublist(center, center + 4);
            for (var c = 0; c < 4; c++) {
              expect(
                pixel[c],
                closeTo(reference[center + c], 1),
                reason: '$type channel $c',
              );
            }
            assets.release(model);
            expect((await render(scene)).sublist(center, center + 4), pixel);
            scene.remove(group);
            await render(scene);
          } finally {
            await assets.close();
          }
        }
        final empty = Scene();
        await render(empty);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
