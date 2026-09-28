import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_gltf/src/worker.dart';
import '../support/fixtures.dart';
import '../support/pbr_fixture.dart';

final class Cancellation implements LoadCancellation {
  final callbacks = <void Function()>{};
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
      return Registration(() {});
    }
    callbacks.add(callback);
    return Registration(() => callbacks.remove(callback));
  }

  void cancel() {
    isCancelled = true;
    for (final callback in List.of(callbacks)) {
      callback();
    }
  }
}

void check(bool value) {
  if (!value) throw StateError('AOT fixture failed.');
}

final class ModelSources implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(
        effectiveUri: uri,
        bytes: uri.path.endsWith('pbr.glb')
            ? pbrModel(
                material: {
                  'pbrMetallicRoughness': {
                    'baseColorTexture': {'index': 0},
                  },
                  'normalTexture': {'index': 0},
                  'emissiveTexture': {'index': 0},
                },
              )
            : texturedModel(),
      );
}

final class ModelImages implements ImageDecoder {
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async => ImageData(pixels: Uint8List(16), size: PhysicalSize(2, 2));
}

Future<void> main() async {
  final token = Cancellation();
  final document = await GltfWorkers.parse(
    Uint8List.fromList(utf8.encode('{"asset":{"version":"2.0"}}')),
    const GltfLimits(),
    token,
  );
  check((document.root['asset'] as Map)['version'] == '2.0');
  final data = await GltfWorkers.dataUri(
    'data:application/octet-stream;base64,AID/',
    3,
    const {'application/octet-stream'},
    token,
    'buffers[0].uri',
  );
  final accessors = await GltfWorkers.accessors(
    {
      'buffers': [
        {'byteLength': 3},
      ],
      'bufferViews': [
        {'buffer': 0, 'byteLength': 3},
      ],
      'accessors': [
        {
          'bufferView': 0,
          'componentType': 5121,
          'type': 'VEC3',
          'count': 1,
          'normalized': true,
        },
      ],
    },
    [data],
    const GltfLimits(),
    12,
    token,
  );
  final values = accessors.single.values;
  check(
    values[0] == 0 && (values[1] - 128 / 255).abs() < 1e-6 && values[2] == 1,
  );
  try {
    await GltfWorkers.parse(Uint8List(0), const GltfLimits(), token);
    throw StateError('Malformed document was accepted.');
  } on AssetLoadException catch (error) {
    check(error.code == AssetLoadError.invalidData && error.fieldPath != null);
  }
  final cancelled = Cancellation();
  final pending = GltfWorkers.parse(
    Uint8List.fromList(utf8.encode('{"asset":{"version":"2.0"}}')),
    const GltfLimits(),
    cancelled,
  );
  final outcome = pending.then<void>(
    (_) => throw StateError('Cancelled worker returned.'),
    onError: (Object error) {
      check(error is LoadCancelled);
    },
  );
  cancelled.cancel();
  await outcome;
  check(token.callbacks.isEmpty && cancelled.callbacks.isEmpty);
  final existingGeometry = BoxGeometry();
  final existingImage = TextureImage.rgba(
    width: 1,
    height: 1,
    pixels: Uint8List(4),
  );
  final scope = AssetScope(
    services: AssetServices(
      resolver: ModelSources(),
      imageDecoder: ModelImages(),
    ),
  );
  final model = await scope.load(Gltf.asset('model.glb')).result;
  final instance = model.instantiate();
  final mesh = instance.children.single.children.single as Mesh;
  check(mesh.geometry.id > existingGeometry.id);
  check(mesh.material.colorMap!.image.id > existingImage.id);
  check(mesh.geometry.vertexCount == 4 && mesh.geometry.indices.length == 6);
  check(mesh.material.side == MaterialSide.front);
  final pbr = await scope.load(Gltf.asset('pbr.glb')).result;
  final pbrInstance = pbr.instantiate();
  final standard =
      (pbrInstance.children.first.children.single as Mesh).material
          as StandardMaterial;
  check(identical(standard.baseColorMap!.image, standard.emissiveMap!.image));
  check(
    standard.normalMap!.image.descriptor.format == TextureFormat.rgba8Unorm,
  );
  check(
    standard.baseColorMap!.image.descriptor.format ==
        TextureFormat.rgba8UnormSrgb,
  );
  check(pbrInstance.children.last.children.single is DirectionalLight);
  await scope.close();
  check(model.isReleased && mesh.material.colorMap != null);
  print('AOT glTF workers passed.');
}
