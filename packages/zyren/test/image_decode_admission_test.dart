import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'asset_budget_test.dart' show Resolver, Loader, objectAsset, loadError;

class BusyDecoder implements ImageDecoder {
  final int busyCalls;
  final ImageDecodeError error;
  int calls = 0;
  final entered = Completer<void>();
  BusyDecoder(this.busyCalls, {this.error = ImageDecodeError.busy});
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    if (calls <= busyCalls) throw ImageDecodeException(error, 'Test decoder');
    return ImageData(pixels: Uint8List(4), size: PhysicalSize(1, 1));
  }
}

void main() {
  late AssetScope scope;
  late int reads;
  LoadTask<Object> load(BusyDecoder decoder) {
    reads = 0;
    scope = AssetScope(
      services: AssetServices(
        imageDecoder: decoder,
        resolver: Resolver((uri, _) async {
          reads++;
          return ResolvedSource(effectiveUri: uri, bytes: Uint8List(1));
        }),
      ),
    );
    return scope.load(
      AssetRequest(
        uri: Uri.parse('asset:///image'),
        loader: Loader((source, context) async {
          await context.decodeImage(source.bytes, fieldPath: 'images[0]');
          expect(context.decodedBytes, 4);
          return objectAsset();
        }),
      ),
    );
  }

  tearDown(() => scope.close());

  test(
    'busy images retry without downloading again or spending twice',
    () async {
      final decoder = BusyDecoder(3);
      await load(decoder).result;
      expect(decoder.calls, 4);
      expect(reads, 1);
    },
  );

  test('malformed images are not retried', () async {
    final decoder = BusyDecoder(100, error: ImageDecodeError.invalidData);
    await expectLater(
      load(decoder).result,
      throwsA(loadError(AssetLoadError.invalidData)),
    );
    expect(decoder.calls, 1);
  });

  test('cancelling a busy image stops admission retries', () async {
    final decoder = BusyDecoder(100);
    final task = load(decoder);
    final result = expectLater(task.result, throwsA(isA<LoadCancelled>()));
    await decoder.entered.future;
    task.cancel();
    await result;
    await scope.close();
    expect(decoder.calls, 1);
  });

  test('an unavailable decoder eventually fails with the image path', () async {
    final decoder = BusyDecoder(1000);
    await expectLater(
      load(decoder).result,
      throwsA(
        loadError(
          AssetLoadError.decodeFailed,
        ).having((e) => e.fieldPath, 'path', 'images[0]'),
      ),
    );
    expect(decoder.calls, greaterThan(1));
    expect(decoder.calls, lessThanOrEqualTo(32));
  });
}
