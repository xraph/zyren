import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';

class TestBundle extends CachingAssetBundle {
  final data = Completer<ByteData>();
  final keys = <String>[];
  @override
  Future<ByteData> load(String key) {
    keys.add(key);
    return data.future;
  }
}

class Value {
  final List<int> bytes;
  bool released = false;
  Value(this.bytes);
}

class Loader extends AssetLoader<Value> {
  @override
  Future<DecodedAsset<Value>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async => DecodedAsset(
    create: () => Value(source.bytes),
    release: (value) => value.released = true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'detached controllers share CPU services without creating a GPU backend',
    () async {
      final bundle = TestBundle();
      var backendStarts = 0;
      final runtime = SceneRuntime(
        assetServices: AssetServices(
          resolver: FlutterSourceResolver(bundle: bundle),
        ),
        backendFactory: () async {
          backendStarts++;
          throw StateError('No GPU needed.');
        },
      );
      final first = SceneController(runtime: runtime),
          second = SceneController(runtime: runtime);
      final request = AssetRequest(
        uri: Uri.parse('asset:///models/part.bin'),
        loader: Loader(),
      );
      final a = first.assets.load(request), b = second.assets.load(request);
      bundle.data.complete(Uint8List.fromList([1, 2, 3]).buffer.asByteData());
      final values = await Future.wait([a.result, b.result]);
      expect(bundle.keys, ['models/part.bin']);
      expect(backendStarts, 0);
      expect(values[0], isNot(same(values[1])));
      expect(values[0].bytes, [1, 2, 3]);
      first.dispose();
      await first.whenDisposed;
      expect(values[0].released, isTrue);
      expect(values[1].released, isFalse);
      second.dispose();
      await second.whenDisposed;
      expect(values[1].released, isTrue);
      expect(backendStarts, 0);
    },
  );

  test('bundle loading honours byte-data offsets and size limits', () async {
    final bytes = Uint8List.fromList([90, 1, 2, 3, 91]);
    for (final limit in [3, 2]) {
      final bundle = TestBundle()
        ..data.complete(ByteData.sublistView(bytes, 1, 4));
      final scope = AssetScope(
        services: AssetServices(
          resolver: FlutterSourceResolver(bundle: bundle),
          limits: AssetLimits(maxSourceBytes: limit),
        ),
      );
      final task = scope.load(
        AssetRequest(uri: Uri.parse('asset:///part.bin'), loader: Loader()),
      );
      if (limit == 3) {
        expect((await task.result).bytes, [1, 2, 3]);
      } else {
        await expectLater(
          task.result,
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.code,
              'code',
              AssetLoadError.limitExceeded,
            ),
          ),
        );
      }
      await scope.close();
    }
  });

  test('bundle key validation rejects encoded path separators', () async {
    final bundle = TestBundle();
    final scope = AssetScope(
      services: AssetServices(resolver: FlutterSourceResolver(bundle: bundle)),
    );
    for (final uri in [
      'asset:///models%2Fpart.bin',
      'asset:///models%5Cpart.bin',
      'asset://remote/part.bin',
    ]) {
      await expectLater(
        scope.load(AssetRequest(uri: Uri.parse(uri), loader: Loader())).result,
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.forbiddenReference,
          ),
        ),
      );
    }
    expect(bundle.keys, isEmpty);
    await scope.close();
  });

  test(
    'disposal cancels pending bundle results and drops late bytes',
    () async {
      final bundle = TestBundle();
      final controller = SceneController(
        runtime: SceneRuntime(
          assetServices: AssetServices(
            resolver: FlutterSourceResolver(bundle: bundle),
          ),
        ),
      );
      final task = controller.assets.load(
        AssetRequest(uri: Uri.parse('asset:///late.bin'), loader: Loader()),
      );
      final progress = task.progress.toList();
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      await controller.whenDisposed;
      await expectLater(task.result, throwsA(isA<LoadCancelled>()));
      await progress;
      bundle.data.complete(Uint8List(4).buffer.asByteData());
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'default services load HDR bundle assets before a view attaches',
    () async {
      var backendStarts = 0;
      final bytes = Uint8List.fromList([
        ...ascii.encode('#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n'),
        128,
        64,
        32,
        130,
      ]);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler('flutter/assets', (message) async {
        expect(
          utf8.decode(
            message!.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          ),
          'hdr/default.hdr',
        );
        return ByteData.sublistView(bytes);
      });
      final controller = SceneController(
        runtime: SceneRuntime(
          backendFactory: () async {
            backendStarts++;
            throw StateError('HDR assets do not need a renderer.');
          },
        ),
      );
      try {
        final image = await controller.assets
            .load(
              AssetRequest(
                uri: Uri.parse('asset:///hdr/default.hdr'),
                loader: const HdrImageLoader(),
              ),
            )
            .result;
        expect(image.pixels, [2, 1, .5, 1]);
        expect(backendStarts, 0);
      } finally {
        controller.dispose();
        await controller.whenDisposed;
        messenger.setMockMessageHandler('flutter/assets', null);
      }
    },
  );

  test('native presets expose the same default CPU service instance', () {
    expect(
      const SceneRuntime().assetServices,
      same(const SceneRuntime.nativeMetal().assetServices),
    );
    expect(
      const SceneRuntime().assetServices,
      same(const SceneRuntime.nativeAndroid().assetServices),
    );
  });
}
