import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

class MemorySource implements ByteSourceResolver {
  final Uint8List bytes;
  MemorySource(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}

Future<Uint8List> compressedQuad() async {
  final mesh = await File(
    '../../test_assets/compression/quad-edgebreaker.drc',
  ).readAsBytes();
  final texture = await File(
    '../../test_assets/compression/colors-uastc.ktx2',
  ).readAsBytes();
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'asset': {'version': '2.0'},
        'extensionsUsed': [
          'KHR_draco_mesh_compression',
          'KHR_texture_basisu',
          'KHR_materials_unlit',
        ],
        'extensionsRequired': [
          'KHR_draco_mesh_compression',
          'KHR_texture_basisu',
        ],
        'buffers': [
          {
            'byteLength': mesh.length,
            'uri': 'data:application/octet-stream;base64,${base64Encode(mesh)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteLength': mesh.length},
        ],
        'accessors': [
          {
            'componentType': 5126,
            'count': 4,
            'type': 'VEC3',
            'min': [-1, -1, 0],
            'max': [1, 1, 0],
          },
          {'componentType': 5126, 'count': 4, 'type': 'VEC3'},
          {'componentType': 5126, 'count': 4, 'type': 'VEC2'},
          {'componentType': 5125, 'count': 6, 'type': 'SCALAR'},
        ],
        'images': [
          {
            'uri': 'data:image/ktx2;base64,${base64Encode(texture)}',
            'mimeType': 'image/ktx2',
          },
        ],
        'textures': [
          {
            'extensions': {
              'KHR_texture_basisu': {'source': 0},
            },
          },
        ],
        'materials': [
          {
            'extensions': {'KHR_materials_unlit': {}},
            'pbrMetallicRoughness': {
              'baseColorTexture': {'index': 0},
            },
          },
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0, 'NORMAL': 1, 'TEXCOORD_0': 2},
                'indices': 3,
                'material': 0,
                'extensions': {
                  'KHR_draco_mesh_compression': {
                    'bufferView': 0,
                    'attributes': {
                      'POSITION': 77,
                      'NORMAL': 8,
                      'TEXCOORD_0': 21,
                    },
                  },
                },
              },
            ],
          },
        ],
        'nodes': [
          {'mesh': 0},
        ],
        'scenes': [
          {
            'nodes': [0],
          },
        ],
        'scene': 0,
      }),
    ),
  );
}

void main() {
  test(
    'compressed glTF reaches Metal pixels and releases scene resources',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()..background = const Color3(0, 0, 0);
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
      Future<ReadbackOutput> draw() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(63, 63),
                ),
              )
              as ReadbackOutput;
      try {
        for (final bytes in [
          await File(
            '../../test_assets/compression/triangle.glb',
          ).readAsBytes(),
          await compressedQuad(),
        ]) {
          final scope = AssetScope(
            services: AssetServices(
              resolver: MemorySource(bytes),
              bufferDecoder: const NativeBufferDecoder(),
              meshDecoder: const NativeMeshDecoder(),
              textureDecoder: NativeTextureDecoder.forDevice(
                backend.capabilities,
              ),
            ),
          );
          try {
            final asset = await scope.load(Gltf.asset('compressed.glb')).result;
            final root = scene.add(asset.instantiate());
            Iterable<Object3D> nodes(Object3D node) sync* {
              yield node;
              for (final child in node.children) {
                yield* nodes(child);
              }
            }

            for (final node in nodes(root)) {
              if (node is Mesh) {
                if (node.material.colorMap case final map?) {
                  expect(
                    backend.capabilities.textureFormats,
                    contains(map.image.descriptor.format),
                  );
                  final compressed =
                      NativeTextureDecoder.forDevice(
                        backend.capabilities,
                      ).target !=
                      TextureTranscodeTarget.rgba8;
                  expect(map.image.descriptor.format.isCompressed, compressed);
                  expect(
                    map.image.descriptor.byteLength,
                    compressed ? 112 : 340,
                  );
                }
              }
            }
            final frame = await draw();
            expect(frame.stats.triangles, greaterThan(0));
            expect(
              frame.image.pixels.indexed
                  .where((v) => v.$1 % 4 != 3 && v.$2 > 50)
                  .length,
              greaterThan(100),
            );
            expect(
              (await backend.resourceStats()).residentBytes,
              greaterThan(0),
            );
            scene.remove(root);
            await draw();
            expect((await backend.resourceStats()).residentBytes, 0);
          } finally {
            await scope.close();
          }
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
