import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'support/fixtures.dart';

const extension = 'EXT_meshopt_compression';

Map<String, Object?> document({bool required = true}) => {
  'asset': {'version': '2.0'},
  'extensionsUsed': [extension],
  if (required) 'extensionsRequired': [extension],
  'buffers': [
    {'byteLength': 36},
    {
      'byteLength': 36,
      'extensions': {
        extension: {'fallback': true},
      },
    },
  ],
  'bufferViews': [
    {
      'buffer': 1,
      'byteLength': 36,
      'extensions': {
        extension: {
          'buffer': 0,
          'byteLength': 36,
          'byteStride': 12,
          'count': 3,
          'mode': 'ATTRIBUTES',
        },
      },
    },
  ],
  'accessors': [
    {
      'bufferView': 0,
      'componentType': 5126,
      'count': 3,
      'type': 'VEC3',
      'min': [-1, -1, 0],
      'max': [1, 1, 0],
    },
  ],
  'meshes': [
    {
      'primitives': [
        {
          'attributes': {'POSITION': 0},
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
};

Map<String, Object?> entry(Map<String, Object?> root, String field, int i) =>
    (root[field] as List)[i] as Map<String, Object?>;
Map<String, Object?> compression(Map<String, Object?> root) =>
    (entry(root, 'bufferViews', 0)['extensions'] as Map)[extension]
        as Map<String, Object?>;

class Decoder implements BufferDecoder {
  int calls = 0;
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Set<BufferEncoding> get encodings => {BufferEncoding.meshopt};
  @override
  Future<Uint8List> decode(
    Uint8List bytes, {
    required BufferDecodeOptions options,
    int maxDecodedBytes = 64 * 1024 * 1024,
  }) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    return Uint8List.fromList(bytes);
  }
}

class Sources implements ByteSourceResolver {
  final Uint8List bytes;
  final List<Uri> reads = [];
  Sources(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads.add(uri);
    if (reads.length > 1) throw StateError('Fallback must not be fetched.');
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}

Future<ModelAsset> load(
  Map<String, Object?> root, {
  Decoder? decoder,
  int budget = 4096,
  List<double>? positions,
}) async {
  final bytes = Float32List.fromList(
    positions ?? [-1, -1, 0, 1, -1, 0, 0, 1, 0],
  ).buffer.asUint8List();
  final scope = AssetScope(
    services: AssetServices(
      resolver: Sources(glb(root, binary: bytes)),
      bufferDecoder: decoder,
      limits: AssetLimits(maxDecodedBytes: budget),
    ),
  );
  addTearDown(scope.close);
  return scope.load(Gltf.asset('triangle.glb')).result;
}

Matcher failure(AssetLoadError code) =>
    isA<AssetLoadException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'cancelled compressed models are not published after native completion',
    () async {
      final decoder = Decoder()..gate = Completer<void>();
      final bytes = Float32List.fromList([
        -1,
        -1,
        0,
        1,
        -1,
        0,
        0,
        1,
        0,
      ]).buffer.asUint8List();
      final scope = AssetScope(
        services: AssetServices(
          resolver: Sources(glb(document(), binary: bytes)),
          bufferDecoder: decoder,
        ),
      );
      final task = scope.load(Gltf.asset('triangle.glb'));
      final cancelled = expectLater(task.result, throwsA(isA<LoadCancelled>()));
      await decoder.entered.future;
      await scope.close();
      decoder.gate!.complete();
      await cancelled;
      expect(await load(document(), decoder: Decoder()), isA<ModelAsset>());
    },
  );
  test(
    'required meshopt views decode without fetching explicit or implicit fallback',
    () async {
      for (final uri in [null, 'fallback.bin']) {
        final root = document(), decoder = Decoder();
        if (uri != null) entry(root, 'buffers', 1)['uri'] = uri;
        final model = await load(root, decoder: decoder);
        final mesh =
            model.instantiate().children.single.children.single as Mesh;
        expect(mesh.geometry.positions, [-1, -1, 0, 1, -1, 0, 0, 1, 0]);
        expect(decoder.calls, 1);
      }
      final root = document();
      entry(root, 'buffers', 1).remove('extensions');
      expect(await load(root, decoder: Decoder()), isA<ModelAsset>());
    },
  );

  test(
    'missing codec rejects required extension but optional uses ordinary bytes',
    () async {
      await expectLater(
        load(document()),
        throwsA(failure(AssetLoadError.unsupportedFeature)),
      );
      final root = document(required: false);
      entry(root, 'bufferViews', 0)['buffer'] = 0;
      (root['buffers'] as List).removeLast();
      final model = await load(root);
      expect(model.issues.single.code, 'gltf.unsupportedOptionalExtension');
      expect(model.instantiate(), isA<Group>());
    },
  );

  test('metadata and fallback ranges fail before invoking the codec', () async {
    for (final modify in <void Function(Map<String, Object?>)>[
      (r) => compression(r)['count'] = 4,
      (r) => compression(r)['byteStride'] = 13,
      (r) => compression(r)['filter'] = 'QUATERNION',
      (r) => compression(r)['byteOffset'] = 1,
      (r) => compression(r)['buffer'] = 1,
      (r) => entry(r, 'buffers', 1)['byteLength'] = 35,
      (r) => entry(r, 'bufferViews', 0)['byteStride'] = 16,
      (r) => (r['bufferViews'] as List).add({'buffer': 1, 'byteLength': 4}),
      (r) => r.remove('extensionsRequired'),
      (r) => r.remove('extensionsUsed'),
    ]) {
      final root = document(), decoder = Decoder();
      modify(root);
      await expectLater(
        load(root, decoder: decoder),
        throwsA(failure(AssetLoadError.invalidData)),
      );
      expect(decoder.calls, 0);
    }
  });

  test(
    'decompressed accessors still enforce finite values and alignment',
    () async {
      await expectLater(
        load(
          document(),
          decoder: Decoder(),
          positions: [double.nan, -1, 0, 1, -1, 0, 0, 1, 0],
        ),
        throwsA(failure(AssetLoadError.invalidData)),
      );
      final root = document();
      entry(root, 'bufferViews', 0)['byteOffset'] = 1;
      entry(root, 'buffers', 1)['byteLength'] = 37;
      await expectLater(
        load(root, decoder: Decoder()),
        throwsA(failure(AssetLoadError.invalidData)),
      );
    },
  );

  test('output is charged before decoding and accessor conversion', () async {
    final decoder = Decoder();
    await expectLater(
      load(document(), decoder: decoder, budget: 35),
      throwsA(failure(AssetLoadError.limitExceeded)),
    );
    expect(decoder.calls, 0);
    await expectLater(
      load(document(), decoder: Decoder(), budget: 36),
      throwsA(failure(AssetLoadError.limitExceeded)),
    );
  });
}
