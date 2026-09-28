import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'asset_budget_test.dart' show Resolver, Loader, objectAsset, loadError;

class Decoder implements TextureDecoder {
  ImageDecodeLimits? received;
  final entered = Completer<void>();
  final Completer<void>? gate;
  Decoder({this.gate});
  @override
  Set<TextureEncoding> get encodings => const {TextureEncoding.ktx2Basis};
  @override
  Future<TextureImageData> decode(
    Uint8List bytes, {
    required TextureEncoding encoding,
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    received = limits;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    return TextureImageData.rgba(
      width: 2,
      height: 2,
      pixels: Uint8List(16),
      mipmaps: [Uint8List(4)],
    );
  }
}

void main() {
  test(
    'cancellation waits for physical texture completion before dropping output',
    () async {
      final gate = Completer<void>(), finished = Completer<void>();
      final decoder = Decoder(gate: gate);
      final scope = AssetScope(
        services: AssetServices(
          resolver: Resolver(
            (uri, _) async =>
                ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
          ),
          textureDecoder: decoder,
        ),
      );
      var delivered = false;
      final task = scope.load(
        AssetRequest(
          uri: Uri.parse('asset:///cancel'),
          loader: Loader((_, context) async {
            try {
              await context.decodeTexture(
                Uint8List(1),
                encoding: TextureEncoding.ktx2Basis,
              );
              delivered = true;
              return objectAsset();
            } finally {
              finished.complete();
            }
          }),
        ),
      );
      final cancelled = expectLater(task.result, throwsA(isA<LoadCancelled>()));
      await decoder.entered.future;
      await scope.close();
      await cancelled;
      expect(finished.isCompleted, isFalse);
      gate.complete();
      await finished.future;
      expect(delivered, isFalse);
    },
  );
  test(
    'texture service accounts for authored mips and remaining limits',
    () async {
      Future<void> load(Decoder? decoder, int budget) async {
        final scope = AssetScope(
          services: AssetServices(
            resolver: Resolver(
              (uri, _) async =>
                  ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
            ),
            textureDecoder: decoder,
            limits: AssetLimits(maxDecodedBytes: budget),
          ),
        );
        addTearDown(scope.close);
        await scope
            .load(
              AssetRequest(
                uri: Uri.parse('asset:///texture'),
                loader: Loader((_, context) async {
                  expect(
                    context.supportsTextureEncoding(TextureEncoding.ktx2Basis),
                    decoder != null,
                  );
                  context.reserveDecodedBytes(3);
                  final texture = await context.decodeTexture(
                    Uint8List(1),
                    encoding: TextureEncoding.ktx2Basis,
                  );
                  expect(texture.levels.length, 2);
                  expect(context.decodedBytes, 23);
                  return objectAsset();
                }),
              ),
            )
            .result;
      }

      await expectLater(
        load(null, 23),
        throwsA(loadError(AssetLoadError.unsupportedFeature)),
      );
      final decoder = Decoder();
      await load(decoder, 23);
      expect(decoder.received!.maxDecodedBytes, 20);
      await expectLater(
        load(decoder, 22),
        throwsA(loadError(AssetLoadError.limitExceeded)),
      );
    },
  );
}
