import 'dart:async';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'tangent_generator_test.dart' show mirroredQuad;

class _Source implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: Uint8List.fromList([1]));
}

class _Generator implements TangentGenerator {
  final entered = Completer<void>(), release = Completer<void>();
  int calls = 0;
  late GeometryData output;
  @override
  Future<GeometryData> generate(
    GeometryData geometry, {
    int uvSet = 0,
    TangentGenerationLimits limits = const TangentGenerationLimits(),
  }) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return output;
  }
}

class _ConcurrentLoader extends AssetLoader<GeometryData> {
  const _ConcurrentLoader();
  @override
  Object get cacheKey => 'two-tangent-jobs';
  @override
  Future<DecodedAsset<GeometryData>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final results = await Future.wait([
      context.generateTangents(mirroredQuad(), fieldPath: 'first'),
      context.generateTangents(mirroredQuad(), fieldPath: 'second'),
    ]);
    return DecodedAsset(create: () => results.first, release: (_) {});
  }
}

void main() {
  test(
    'concurrent tangent requests cannot spend the same remaining budget',
    () async {
      final generator = _Generator()
        ..output = mirroredQuad().withCornerTangents(
          Float32List.fromList([
            for (var i = 0; i < 6; i++) ...[1, 0, 0, 1],
          ]),
        );
      final scope = AssetScope(
        services: AssetServices(
          resolver: _Source(),
          tangentGenerator: generator,
          limits: AssetLimits(maxDecodedBytes: generator.output.byteLength),
        ),
      );
      addTearDown(scope.close);
      final result = scope
          .load(
            AssetRequest(
              uri: Uri.parse('asset:///mesh'),
              loader: const _ConcurrentLoader(),
            ),
          )
          .result;
      final failed = expectLater(
        result,
        throwsA(
          isA<AssetLoadException>()
              .having((e) => e.code, 'code', AssetLoadError.limitExceeded)
              .having((e) => e.fieldPath, 'path', 'second'),
        ),
      );
      await generator.entered.future;
      expect(generator.calls, 1);
      generator.release.complete();
      await failed;
      expect(generator.calls, 1);
    },
  );
}
