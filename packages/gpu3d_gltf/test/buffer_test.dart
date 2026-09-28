import 'dart:convert';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/src/buffers.dart';
import 'package:gpu3d_gltf/src/document.dart';
import 'package:test/test.dart';
import 'container_test.dart' show glb;

class Sources implements ByteSourceResolver {
  final Map<Uri, ResolvedSource> files;
  final reads = <Uri>[];
  Sources(this.files);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads.add(uri);
    return files[uri]!;
  }
}

class BuffersLoader extends AssetLoader<List<Uint8List>> {
  @override
  Future<DecodedAsset<List<Uint8List>>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final document = GltfDocument.parse(source.bytes);
    final buffers = await resolveBuffers(
      document,
      context,
      source.effectiveUri,
    );
    return DecodedAsset(
      create: () => List.unmodifiable(buffers),
      release: (_) {},
    );
  }
}

final root = Uri.parse('asset:///models/start.gltf');
Map<String, Object?> document(List<Object?> buffers) => {
  'asset': {'version': '2.0'},
  'buffers': buffers,
};
Future<List<Uint8List>> load(
  Uint8List bytes, {
  List<ResolvedSource> dependencies = const [],
  Uri? effectiveUri,
}) async {
  final resolver = Sources({
    root: ResolvedSource(effectiveUri: effectiveUri ?? root, bytes: bytes),
    for (final source in dependencies) source.effectiveUri: source,
  });
  final scope = AssetScope(services: AssetServices(resolver: resolver));
  try {
    return await scope
        .load(AssetRequest(uri: root, loader: BuffersLoader()))
        .result;
  } finally {
    await scope.close();
  }
}

void main() {
  test('GLB binary accepts up to three zero padding bytes only', () async {
    final doc = document([
      {'byteLength': 3},
    ]);
    expect((await load(glb(doc, binary: [1, 2, 3]))).single, [1, 2, 3]);
    final bad = glb(doc, binary: [1, 2, 3])..last = 1;
    await expectLater(load(bad), throwsA(isA<AssetLoadException>()));
    await expectLater(
      load(glb(doc, binary: List.filled(8, 0))),
      throwsA(isA<AssetLoadException>()),
    );
  });
  test('buffer references resolve from a redirected base URI', () async {
    final doc = document([
      {'byteLength': 4, 'uri': '../shared.bin'},
    ]);
    final data = await load(
      Uint8List.fromList(utf8.encode(jsonEncode(doc))),
      effectiveUri: Uri.parse('asset:///models/pump/model.gltf'),
      dependencies: [
        ResolvedSource(
          effectiveUri: Uri.parse('asset:///models/shared.bin'),
          bytes: Uint8List.fromList([1, 2, 3, 4, 5]),
        ),
      ],
    );
    expect(data.single, [1, 2, 3, 4]);
  });
  test(
    'embedded buffer decoding checks MIME, length and percent-encoded padding',
    () async {
      final doc = document([
        {
          'byteLength': 1,
          'uri': 'data:application/octet-stream;base64,AQ%3D%3D',
        },
      ]);
      expect(
        (await load(Uint8List.fromList(utf8.encode(jsonEncode(doc))))).single,
        [1],
      );
      final trailing = document([
        {'byteLength': 1, 'uri': 'data:application/octet-stream;base64,AQID'},
      ]);
      expect(
        (await load(
          Uint8List.fromList(utf8.encode(jsonEncode(trailing))),
        )).single,
        [1],
      );
      for (final uri in [
        'data:text/plain;base64,AQ==',
        'data:application/octet-stream,A',
        'data:application/octet-stream;base64,!!!!',
      ]) {
        final bad = document([
          {'byteLength': 1, 'uri': uri},
        ]);
        await expectLater(
          load(Uint8List.fromList(utf8.encode(jsonEncode(bad)))),
          throwsA(isA<AssetLoadException>()),
        );
      }
    },
  );
  test('bundle references cannot escape to filesystem sources', () async {
    final doc = document([
      {'byteLength': 1, 'uri': 'file:///private/asset.bin'},
    ]);
    await expectLater(
      load(Uint8List.fromList(utf8.encode(jsonEncode(doc)))),
      throwsA(
        isA<AssetLoadException>().having(
          (e) => e.code,
          'code',
          AssetLoadError.forbiddenReference,
        ),
      ),
    );
  });
}
