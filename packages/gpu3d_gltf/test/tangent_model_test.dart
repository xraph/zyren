import 'dart:async';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:test/test.dart';
import 'geometry_model_test.dart' show onlyMesh;
import 'image_model_test.dart' show ImageSources, Images, scopeFor;
import 'support/fixtures.dart';
import 'support/pbr_fixture.dart';

class TestTangents implements TangentGenerator {
  int calls = 0, selectedUv = -1;
  GeometryData? input;
  final entered = Completer<void>();
  Completer<void>? gate;
  TangentGenerationException? failure;
  @override
  Future<GeometryData> generate(
    GeometryData geometry, {
    int uvSet = 0,
    TangentGenerationLimits limits = const TangentGenerationLimits(),
  }) async {
    calls++;
    selectedUv = uvSet;
    input = geometry;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (failure case final error?) throw error;
    return geometry.withCornerTangents(
      Float32List.fromList([
        for (var i = 0; i < geometry.indices.length; i++) ...[1, 0, 0, 1],
      ]),
      limits: limits,
    );
  }
}

Uint8List normalMapped({
  bool flat = false,
  bool authored = false,
  int uvSet = 0,
}) => editModel(
  pbrModel(
    material: {
      'normalTexture': {'index': 2, 'texCoord': uvSet},
    },
  ),
  (root) {
    root['scenes'] = [
      {
        'nodes': [0],
      },
    ];
    final attributes =
        (root['meshes'] as List).first['primitives'][0]['attributes'] as Map;
    if (!authored) attributes.remove('TANGENT');
    if (flat) attributes.remove('NORMAL');
    if (uvSet == 1) attributes['TEXCOORD_1'] = attributes['TEXCOORD_0'];
  },
);

void main() {
  test(
    'normal map selects UV1 and flat normals discard authored tangents',
    () async {
      final generator = TestTangents();
      final scope = scopeFor(
        ImageSources(normalMapped(flat: true, authored: true, uvSet: 1)),
        Images(),
        tangentGenerator: generator,
      );
      final result = await scope.load(Gltf.asset('normal.glb')).result;
      expect(generator.calls, 1);
      expect(generator.selectedUv, 1);
      expect(
        generator.input!.attributes.containsKey(VertexSemantic.tangent),
        isFalse,
      );
      expect(generator.input!.layout.vertexCount, 6);
      expect(
        onlyMesh(result).geometry.attributes[VertexSemantic.tangent],
        isNotNull,
      );
    },
  );
  test('authored tangent basis bypasses the generator', () async {
    final generator = TestTangents();
    final scope = scopeFor(
      ImageSources(normalMapped(authored: true)),
      Images(),
      tangentGenerator: generator,
    );
    final result = await scope.load(Gltf.asset('normal.glb')).result;
    expect(generator.calls, 0);
    expect(
      onlyMesh(result).geometry.attributes[VertexSemantic.tangent],
      isNotNull,
    );
  });
  test(
    'missing service and native failures retain source and primitive path',
    () async {
      for (final (generator, code) in <(TangentGenerator?, AssetLoadError)>[
        (null, AssetLoadError.unsupportedFeature),
        (
          TestTangents()
            ..failure = const TangentGenerationException(
              TangentGenerationError.limitExceeded,
              'budget',
            ),
          AssetLoadError.limitExceeded,
        ),
        (
          TestTangents()
            ..failure = const TangentGenerationException(
              TangentGenerationError.invalidData,
              'bad basis',
            ),
          AssetLoadError.invalidData,
        ),
      ]) {
        final scope = scopeFor(
          ImageSources(normalMapped()),
          Images(),
          tangentGenerator: generator,
        );
        await expectLater(
          scope.load(Gltf.asset('normal.glb')).result,
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', code)
                .having(
                  (e) => e.issue.sourceUri,
                  'source',
                  Uri.parse('asset:///normal.glb'),
                )
                .having(
                  (e) => e.fieldPath,
                  'field',
                  'meshes[0].primitives[0].attributes.TANGENT',
                ),
          ),
        );
      }
    },
  );
  test('cancellation during generation prevents model publication', () async {
    final generator = TestTangents()..gate = Completer<void>();
    final scope = scopeFor(
      ImageSources(normalMapped()),
      Images(),
      tangentGenerator: generator,
    );
    final task = scope.load(Gltf.asset('normal.glb'));
    final result = expectLater(task.result, throwsA(isA<LoadCancelled>()));
    await generator.entered.future;
    task.cancel();
    generator.gate!.complete();
    await result;
  });
  test(
    'replacement geometry participates in the remaining decoded budget',
    () async {
      final generator = TestTangents();
      final scope = scopeFor(
        ImageSources(normalMapped()),
        Images(),
        tangentGenerator: generator,
        limits: const AssetLimits(
          tangents: TangentGenerationLimits(maxOutputBytes: 1),
        ),
      );
      await expectLater(
        scope.load(Gltf.asset('normal.glb')).result,
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
    },
  );
}
