import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'asset_budget_test.dart' show Resolver, Loader, objectAsset, loadError;

class Decoder implements CompressedMeshDecoder {
  final DecodedMeshData mesh;
  int calls = 0;
  Decoder(this.mesh);
  @override
  Set<MeshEncoding> get encodings => const {MeshEncoding.draco};
  @override
  Future<DecodedMeshData> decode(
    Uint8List bytes, {
    required MeshEncoding encoding,
    MeshDecodeLimits limits = const MeshDecodeLimits(),
  }) async {
    calls++;
    return mesh;
  }
}

DecodedMeshData triangle({int lastIndex = 2}) => DecodedMeshData(
  vertexCount: 3,
  indices: Uint32List.fromList([0, 1, lastIndex]),
  attributes: [
    MeshAttributeData(
      id: 5,
      type: MeshScalarType.float32,
      components: 3,
      bytes: Float32List(9).buffer.asUint8List(),
    ),
  ],
);

void main() {
  Future<void> load(Decoder? decoder, int budget) async {
    final scope = AssetScope(
      services: AssetServices(
        resolver: Resolver(
          (uri, _) async =>
              ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
        ),
        meshDecoder: decoder,
        limits: AssetLimits(maxDecodedBytes: budget),
      ),
    );
    addTearDown(scope.close);
    await scope
        .load(
          AssetRequest(
            uri: Uri.parse('asset:///mesh'),
            loader: Loader((_, context) async {
              final mesh = await context.decodeMesh(
                Uint8List(1),
                encoding: MeshEncoding.draco,
              );
              expect(mesh.decodedByteLength, 48);
              expect(context.decodedBytes, 48);
              return objectAsset();
            }),
          ),
        )
        .result;
  }

  test(
    'compressed mesh service checks capability, decoded bytes and topology',
    () async {
      await expectLater(
        load(null, 100),
        throwsA(loadError(AssetLoadError.unsupportedFeature)),
      );
      await load(Decoder(triangle()), 100);
      await expectLater(
        load(Decoder(triangle()), 47),
        throwsA(loadError(AssetLoadError.limitExceeded)),
      );
      await expectLater(
        load(Decoder(triangle(lastIndex: 3)), 100),
        throwsA(loadError(AssetLoadError.invalidData)),
      );
    },
  );
  test('mesh limits reject mismatched attributes and duplicate IDs', () {
    final attribute = triangle().attributes.single;
    final limits = MeshDecodeLimits();
    for (final mesh in [
      DecodedMeshData(
        vertexCount: 3,
        indices: Uint32List(3),
        attributes: [attribute, attribute],
      ),
      DecodedMeshData(
        vertexCount: 4,
        indices: Uint32List(3),
        attributes: [attribute],
      ),
    ]) {
      expect(
        () => limits.validateOutput(mesh),
        throwsA(isA<BufferDecodeException>()),
      );
    }
    expect(
      () => const MeshDecodeLimits(maxVertices: 1000001).validate(),
      throwsArgumentError,
    );
  });
}
