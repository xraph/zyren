import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gpu3d/gpu3d.dart';
import 'asset_budget_test.dart' show Resolver, Loader, objectAsset, loadError;

const vertices = BufferDecodeOptions(
  encoding: BufferEncoding.meshopt,
  count: 3,
  stride: 12,
);

class Decoder implements BufferDecoder {
  final Future<Uint8List> Function(BufferDecodeOptions, int) run;
  Decoder(this.run);
  @override
  Set<BufferEncoding> get encodings => {BufferEncoding.meshopt};
  @override
  Future<Uint8List> decode(
    Uint8List bytes, {
    required BufferDecodeOptions options,
    int maxDecodedBytes = 64 * 1024 * 1024,
  }) => run(options, maxDecodedBytes);
}

AssetScope scopeFor({BufferDecoder? decoder, int budget = 128}) => AssetScope(
  services: AssetServices(
    resolver: Resolver(
      (uri, _) async => ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
    ),
    bufferDecoder: decoder,
    limits: AssetLimits(maxDecodedBytes: budget),
  ),
);

AssetRequest<Object> request(Future<void> Function(AssetDecodeContext) run) =>
    AssetRequest(
      uri: Uri.parse('asset:///compressed'),
      loader: Loader((_, context) async {
        await run(context);
        return objectAsset();
      }),
    );

void main() {
  test('missing buffer codec reports capability and a field error', () async {
    final scope = scopeFor();
    addTearDown(scope.close);
    await expectLater(
      scope
          .load(
            request((context) async {
              expect(
                context.supportsBufferEncoding(BufferEncoding.meshopt),
                isFalse,
              );
              await context.decodeBuffer(
                Uint8List(1),
                options: vertices,
                fieldPath: 'bufferViews[0]',
              );
            }),
          )
          .result,
      throwsA(
        loadError(
          AssetLoadError.unsupportedFeature,
        ).having((e) => e.fieldPath, 'field', 'bufferViews[0]'),
      ),
    );
  });

  test(
    'queued decodes reserve output before spending the shared budget',
    () async {
      final admitted = <int>[];
      final scope = scopeFor(
        budget: 60,
        decoder: Decoder((options, max) async {
          admitted.add(max);
          return Uint8List(options.decodedByteLength);
        }),
      );
      addTearDown(scope.close);
      await expectLater(
        scope
            .load(
              request((context) async {
                await Future.wait([
                  context.decodeBuffer(Uint8List(1), options: vertices),
                  context.decodeBuffer(Uint8List(1), options: vertices),
                ]);
              }),
            )
            .result,
        throwsA(loadError(AssetLoadError.limitExceeded)),
      );
      expect(admitted, [60]);
    },
  );

  test('codec must return the exact declared output length', () async {
    final scope = scopeFor(decoder: Decoder((_, _) async => Uint8List(35)));
    addTearDown(scope.close);
    await expectLater(
      scope
          .load(
            request((context) async {
              await context.decodeBuffer(Uint8List(1), options: vertices);
            }),
          )
          .result,
      throwsA(loadError(AssetLoadError.invalidData)),
    );
  });

  test(
    'cancelled decode finishes physically without delivering its bytes',
    () async {
      final entered = Completer<void>(), gate = Completer<Uint8List>();
      final finished = Completer<void>();
      final scope = scopeFor(
        decoder: Decoder((_, _) {
          entered.complete();
          return gate.future;
        }),
      );
      var delivered = false;
      final task = scope.load(
        request((context) async {
          try {
            await context.decodeBuffer(Uint8List(1), options: vertices);
            delivered = true;
          } finally {
            finished.complete();
          }
        }),
      );
      final cancelled = expectLater(task.result, throwsA(isA<LoadCancelled>()));
      await entered.future;
      await scope.close();
      await cancelled;
      expect(finished.isCompleted, isFalse);
      gate.complete(Uint8List(36));
      await finished.future;
      expect(delivered, isFalse);
    },
  );

  test('invalid counts, layouts and filters fail before calling a codec', () {
    for (final options in [
      const BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        count: 0,
        stride: 4,
      ),
      const BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        count: 1,
        stride: 3,
      ),
      const BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        count: 1,
        stride: 260,
      ),
      const BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        count: 4,
        stride: 2,
        mode: BufferDecodeMode.triangles,
      ),
      const BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        count: 3,
        stride: 4,
        mode: BufferDecodeMode.indices,
        filter: BufferDecodeFilter.exponential,
      ),
      const BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        count: 3,
        stride: 12,
        filter: BufferDecodeFilter.octahedral,
      ),
      const BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        count: 3,
        stride: 4,
        filter: BufferDecodeFilter.quaternion,
      ),
    ]) {
      expect(() => options.validate(), throwsA(isA<BufferDecodeException>()));
    }
    expect(
      () => const BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        count: 0x7fffffffffffffff,
        stride: 256,
      ).validate(),
      throwsA(isA<BufferDecodeException>()),
    );
  });
}
