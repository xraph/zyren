import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:test/test.dart';
import 'geometry_model_test.dart' show onlyMesh;
import 'support/fixtures.dart';

class ImageSources implements ByteSourceResolver {
  final Uint8List model;
  final List<Uri> reads = [];
  Uri? modelLocation;
  ImageSources(this.model);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads.add(uri);
    return ResolvedSource(
      effectiveUri: uri.path.endsWith('.glb') ? modelLocation ?? uri : uri,
      bytes: uri.path.endsWith('.glb') ? model : base64Decode(cornersPng),
    );
  }
}

class Images implements ImageDecoder {
  int calls = 0;
  final entered = Completer<void>();
  Completer<void>? gate;
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    return ImageData(
      pixels: Uint8List.fromList([
        255,
        0,
        0,
        128,
        0,
        255,
        0,
        255,
        0,
        0,
        255,
        0,
        255,
        255,
        255,
        255,
      ]),
      size: PhysicalSize(2, 2),
    );
  }
}

AssetScope scopeFor(
  ImageSources source,
  Images images, {
  AssetLimits limits = const AssetLimits(),
  TangentGenerator? tangentGenerator,
}) {
  final scope = AssetScope(
    services: AssetServices(
      resolver: source,
      imageDecoder: images,
      tangentGenerator: tangentGenerator,
      limits: limits,
    ),
  );
  addTearDown(scope.close);
  return scope;
}

void main() {
  test(
    'relative images use the effective base URI and share across templates',
    () async {
      final source = ImageSources(
        texturedModel(imageUri: '../textures/corners.png'),
      )..modelLocation = Uri.parse('https://models.test/current/mesh.glb');
      final images = Images(), scope = scopeFor(source, images);
      final first = scope.load(
        Gltf.uri(Uri.parse('https://models.test/start.glb')),
      );
      final second = scope.load(
        Gltf.uri(Uri.parse('https://models.test/start.glb')),
      );
      final a = await first.result, b = await second.result;
      expect(source.reads, [
        Uri.parse('https://models.test/start.glb'),
        Uri.parse('https://models.test/textures/corners.png'),
      ]);
      expect(images.calls, 1);
      final map = onlyMesh(a).material.colorMap!,
          sibling = onlyMesh(b).material.colorMap!;
      expect(map.image, same(sibling.image));
      expect(map.image.generatesMipmaps, isFalse);
      expect(map.sampler.minFilter, TextureFilter.nearest);
      expect(map.sampler.wrapU, TextureWrap.clampToEdge);
    },
  );
  test(
    'all glTF minification filters map to the correct image and sampler rules',
    () async {
      for (final filter in [9728, 9729, 9984, 9985, 9986, 9987]) {
        final scope = scopeFor(
          ImageSources(texturedModel(minFilter: filter)),
          Images(),
        );
        final asset = await scope.load(Gltf.asset('model.glb')).result;
        final map = onlyMesh(asset).material.colorMap!;
        expect(map.image.generatesMipmaps, filter >= 9984);
        expect(
          map.sampler.minFilter,
          [9728, 9984, 9986].contains(filter)
              ? TextureFilter.nearest
              : TextureFilter.linear,
        );
        expect(
          map.sampler.mipFilter,
          [9984, 9985].contains(filter)
              ? TextureFilter.nearest
              : TextureFilter.linear,
        );
      }
    },
  );
  test(
    'MIME mismatch and forbidden references fail before image decoding',
    () async {
      for (final (bytes, code) in [
        (texturedModel(mimeType: 'image/jpeg'), AssetLoadError.invalidData),
        (
          texturedModel(imageUri: 'file:///private/texture.png'),
          AssetLoadError.forbiddenReference,
        ),
      ]) {
        final images = Images(), scope = scopeFor(ImageSources(bytes), images);
        await expectLater(
          scope.load(Gltf.asset('model.glb')).result,
          throwsA(
            isA<AssetLoadException>().having((e) => e.code, 'code', code),
          ),
        );
        expect(images.calls, 0);
      }
    },
  );
  test(
    'final-consumer cancellation during image work discards late results and permits retry',
    () async {
      final images = Images()..gate = Completer<void>();
      final scope = scopeFor(ImageSources(texturedModel()), images);
      final task = scope.load(Gltf.asset('model.glb'));
      await images.entered.future;
      final cancelled = expectLater(task.result, throwsA(isA<LoadCancelled>()));
      task.cancel();
      await cancelled;
      final retry = scope.load(Gltf.asset('model.glb'));
      images.gate!.complete();
      final model = await retry.result;
      expect(onlyMesh(model).material.colorMap, isNotNull);
      expect(images.calls, 2);
    },
  );
  test(
    'prepared image storage participates in the aggregate decoded budget',
    () async {
      final images = Images();
      final scope = scopeFor(
        ImageSources(texturedModel(imageUri: 'corners.png')),
        images,
        // Accessor and geometry copies use 280 bytes, then 16 decoded pixels
        // and 16 owned texture bytes. Admission must reject the final copy.
        limits: const AssetLimits(maxDecodedBytes: 311),
      );
      await expectLater(
        scope.load(Gltf.asset('model.glb')).result,
        throwsA(
          isA<AssetLoadException>()
              .having((e) => e.code, 'code', AssetLoadError.limitExceeded)
              .having((e) => e.fieldPath, 'path', 'images[0]'),
        ),
      );
      expect(images.calls, 1);
      final enough = scopeFor(
        ImageSources(texturedModel(imageUri: 'corners.png')),
        Images(),
        limits: const AssetLimits(maxDecodedBytes: 312),
      );
      expect(
        onlyMesh(
          await enough.load(Gltf.asset('model.glb')).result,
        ).material.colorMap,
        isNotNull,
      );
    },
  );

  test(
    'embedded image buffer views decode without external requests',
    () async {
      final original = texturedModel();
      final jsonLength = ByteData.sublistView(
        original,
      ).getUint32(12, Endian.little);
      final offset = original.length - 20 - jsonLength - 8;
      final png = base64Decode(cornersPng);
      final bytes = editModel(original, (root) {
        final views = root['bufferViews'] as List;
        root['images'] = [
          {'bufferView': views.length, 'mimeType': 'image/png'},
        ];
        views.add({
          'buffer': 0,
          'byteOffset': offset,
          'byteLength': png.length,
        });
      }, appendBinary: png);
      final source = ImageSources(bytes), images = Images();
      final asset = await scopeFor(
        source,
        images,
      ).load(Gltf.asset('model.glb')).result;
      expect(onlyMesh(asset).material.colorMap!.image.descriptor.width, 2);
      expect(source.reads, hasLength(1));
      expect(images.calls, 1);
    },
  );

  test('sampler variants share decoded pixels but retain mip policy', () async {
    final bytes = editModel(texturedModel(), (root) {
      final materials = root['materials'] as List;
      materials.add({
        'extensions': {'KHR_materials_unlit': <String, Object?>{}},
        'pbrMetallicRoughness': {
          'baseColorTexture': {'index': 1},
        },
      });
      (root['samplers'] as List).add({'minFilter': 9987});
      (root['textures'] as List).add({'source': 0, 'sampler': 1});
      final primitives = (root['meshes'] as List).first['primitives'] as List;
      primitives.add({...primitives.first as Map, 'material': 1});
      primitives.add({...primitives.first as Map, 'material': 0});
    });
    final images = Images();
    final asset = await scopeFor(
      ImageSources(bytes),
      images,
    ).load(Gltf.asset('model.glb')).result;
    final meshes = asset
        .instantiate()
        .children
        .single
        .children
        .cast<Mesh>()
        .toList();
    final maps = meshes.map((m) => m.material.colorMap!).toList();
    expect(images.calls, 1);
    expect(maps[0].image, same(maps[2].image));
    expect(maps[1].image, isNot(same(maps[0].image)));
    expect(maps[0].image.generatesMipmaps, isFalse);
    expect(maps[1].image.generatesMipmaps, isTrue);
  });

  test(
    'scope close cancels a pending image and drops late publication',
    () async {
      final images = Images()..gate = Completer<void>();
      final scope = scopeFor(ImageSources(texturedModel()), images);
      final task = scope.load(Gltf.asset('model.glb'));
      final result = expectLater(task.result, throwsA(isA<LoadCancelled>()));
      await images.entered.future;
      final closing = scope.close();
      images.gate!.complete();
      await closing;
      await result;
    },
  );
}
