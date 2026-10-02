import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'asset_budget_test.dart'
    show Resolver, Loader, Decoder, root, objectAsset, loadError;

class HdrDecoder implements HdrImageDecoder {
  final entered = Completer<void>();
  final List<int> budgets = [];
  final Completer<HdrImageData>? pending;
  HdrDecoder({this.pending});
  @override
  Future<HdrImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    budgets.add(limits.maxDecodedBytes);
    if (!entered.isCompleted) entered.complete();
    return pending == null ? pixel() : pending!.future;
  }
}

HdrImageData pixel() => HdrImageData(
  pixels: Float32List.fromList([2, 4, 8, 1]),
  size: PhysicalSize(1, 1),
);
final resolver = Resolver(
  (uri, context) async =>
      ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
);

void main() {
  test(
    'HDR and byte images share decoded-byte admission within one job',
    () async {
      final hdr = HdrDecoder();
      final bytes = Decoder();
      final scope = AssetScope(
        services: AssetServices(
          resolver: resolver,
          imageDecoder: bytes,
          hdrImageDecoder: hdr,
          limits: const AssetLimits(maxDecodedBytes: 19),
        ),
      );
      try {
        final loader = Loader((source, context) async {
          await Future.wait([
            context.decodeHdrImage(source.bytes, fieldPath: 'environment'),
            context.decodeImage(source.bytes, fieldPath: 'albedo'),
          ]);
          return objectAsset();
        });
        await expectLater(
          scope.load(AssetRequest(uri: root, loader: loader)).result,
          throwsA(
            loadError(
              AssetLoadError.limitExceeded,
            ).having((e) => e.fieldPath, 'field', 'albedo'),
          ),
        );
        expect(hdr.budgets, [19]);
        expect(bytes.remaining, [3]);
      } finally {
        await scope.close();
      }
    },
  );
  test(
    'HDR payload accounting uses float bytes and rejects oversized decoder output',
    () async {
      for (final limits in [
        const AssetLimits(maxDecodedBytes: 15),
        const AssetLimits(images: ImageDecodeLimits(maxDecodedBytes: 15)),
      ]) {
        final scope = AssetScope(
          services: AssetServices(
            resolver: resolver,
            hdrImageDecoder: HdrDecoder(),
            limits: limits,
          ),
        );
        try {
          await expectLater(
            scope
                .load(AssetRequest(uri: root, loader: const HdrImageLoader()))
                .result,
            throwsA(loadError(AssetLoadError.limitExceeded)),
          );
        } finally {
          await scope.close();
        }
      }
    },
  );
  test('HDR loading needs an explicitly installed CPU decoder', () async {
    final scope = AssetScope(services: AssetServices(resolver: resolver));
    try {
      await expectLater(
        scope
            .load(AssetRequest(uri: root, loader: const HdrImageLoader()))
            .result,
        throwsA(
          loadError(
            AssetLoadError.unsupportedFeature,
          ).having((e) => e.issue.sourceUri, 'source', root),
        ),
      );
    } finally {
      await scope.close();
    }
  });
  test(
    'shared HDR decode survives one cancellation and reports float bytes',
    () async {
      final decoded = Completer<HdrImageData>();
      final hdr = HdrDecoder(pending: decoded);
      final services = AssetServices(resolver: resolver, hdrImageDecoder: hdr);
      final first = AssetScope(services: services),
          second = AssetScope(services: services);
      final request = AssetRequest(uri: root, loader: const HdrImageLoader());
      final a = first.load(request), b = second.load(request);
      final progress = <LoadProgress>[];
      final subscription = b.progress.listen(progress.add);
      try {
        await hdr.entered.future;
        final cancelled = expectLater(a.result, throwsA(isA<LoadCancelled>()));
        await first.close();
        await cancelled;
        decoded.complete(pixel());
        final image = await b.result;
        expect(image.pixels, [2, 4, 8, 1]);
        expect(hdr.budgets, hasLength(1));
        expect(
          progress
              .where((p) => p.stage == LoadStage.prepare)
              .single
              .completedBytes,
          16,
        );
        second.release(image);
        expect(image.pixels.first, 2);
      } finally {
        await subscription.cancel();
        await first.close();
        await second.close();
      }
    },
  );
  test('scope close wins over a late HDR decode result', () async {
    final decoded = Completer<HdrImageData>();
    final hdr = HdrDecoder(pending: decoded);
    final scope = AssetScope(
      services: AssetServices(resolver: resolver, hdrImageDecoder: hdr),
    );
    final task = scope.load(
      AssetRequest(uri: root, loader: const HdrImageLoader()),
    );
    final cancelled = expectLater(task.result, throwsA(isA<LoadCancelled>()));
    await hdr.entered.future;
    await scope.close();
    decoded.complete(pixel());
    await cancelled;
    await Future<void>.delayed(Duration.zero);
  });
}
