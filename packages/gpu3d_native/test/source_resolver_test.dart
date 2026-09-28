import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

class BytesLoader extends AssetLoader<ResolvedSource> {
  const BytesLoader();
  @override
  Future<DecodedAsset<ResolvedSource>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async => DecodedAsset(
    create: () =>
        ResolvedSource(effectiveUri: source.effectiveUri, bytes: source.bytes),
    release: (_) {},
  );
}

void main() {
  late HttpServer server;
  late AssetScope scope;
  late Uri root;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    root = Uri.parse('http://127.0.0.1:${server.port}/');
    scope = AssetScope(
      services: const AssetServices(resolver: NativeSourceResolver()),
    );
  });
  tearDown(() async {
    await scope.close();
    await server.close(force: true);
  });
  LoadTask<ResolvedSource> load(String path) => scope.load(
    AssetRequest(uri: root.resolve(path), loader: const BytesLoader()),
  );

  test(
    'HTTP redirects retain effective URI and bounded unknown-length progress',
    () async {
      server.listen((request) async {
        if (request.uri.path == '/start') {
          await request.response.redirect(root.resolve('models/item.bin'));
        } else {
          request.response.add([1, 2, 3, 4]);
          await request.response.close();
        }
      });
      final task = load('start');
      final progress = task.progress.toList();
      final source = await task.result;
      expect(source.bytes, [1, 2, 3, 4]);
      expect(source.effectiveUri, root.resolve('models/item.bin'));
      expect(
        (await progress)
            .where((p) => p.stage == LoadStage.fetch)
            .any((p) => p.totalBytes == null),
        isTrue,
      );
      expect(() => source.bytes[0] = 9, throwsUnsupportedError);
    },
  );

  test('cross-origin redirects are rejected before another request', () async {
    server.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://localhost:${server.port}/other',
      );
      await request.response.close();
    });
    await expectLater(
      load('redirect').result,
      throwsA(
        isA<AssetLoadException>().having(
          (e) => e.code,
          'code',
          AssetLoadError.forbiddenReference,
        ),
      ),
    );
  });

  test(
    'known and unknown response lengths enforce the same byte budget',
    () async {
      await scope.close();
      scope = AssetScope(
        services: const AssetServices(
          resolver: NativeSourceResolver(),
          limits: AssetLimits(maxSourceBytes: 3),
        ),
      );
      server.listen((request) async {
        if (request.uri.path == '/known') request.response.contentLength = 4;
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      for (final path in ['known', 'unknown']) {
        await expectLater(
          load(path).result,
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.code,
              'code',
              AssetLoadError.limitExceeded,
            ),
          ),
        );
      }
    },
  );

  test('gzip admission counts decoded response bytes', () async {
    await scope.close();
    scope = AssetScope(
      services: const AssetServices(
        resolver: NativeSourceResolver(),
        limits: AssetLimits(maxSourceBytes: 64),
      ),
    );
    server.listen((request) async {
      final encoded = gzip.encode(Uint8List(1024));
      request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      request.response.contentLength = encoded.length;
      request.response.add(encoded);
      await request.response.close();
    });
    await expectLater(
      load('gzip').result,
      throwsA(
        isA<AssetLoadException>().having(
          (e) => e.code,
          'code',
          AssetLoadError.limitExceeded,
        ),
      ),
    );
  });

  test('cancellation during response wait settles promptly', () async {
    final started = Completer<void>();
    server.listen((request) {
      started.complete();
    });
    final task = load('waiting');
    final progress = task.progress.toList();
    await started.future;
    task.cancel();
    await expectLater(task.result, throwsA(isA<LoadCancelled>()));
    await progress;
  });

  test('timeout and HTTP failure remain typed source errors', () async {
    await scope.close();
    scope = AssetScope(
      services: const AssetServices(
        resolver: NativeSourceResolver(timeout: Duration(milliseconds: 100)),
      ),
    );
    server.listen((request) async {
      if (request.uri.path == '/missing') {
        request.response.statusCode = 404;
        await request.response.close();
      }
    });
    for (final path in ['missing', 'timeout']) {
      await expectLater(
        load(path).result,
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.sourceFailed,
          ),
        ),
      );
    }
  });

  test('local files use bounded asynchronous reads', () async {
    final directory = await Directory.systemTemp.createTemp('gpu3d-source-');
    try {
      final file = await File(
        '${directory.path}/mesh.bin',
      ).writeAsBytes([4, 3, 2, 1]);
      final source = await scope
          .load(AssetRequest(uri: file.uri, loader: const BytesLoader()))
          .result;
      expect(source.bytes, [4, 3, 2, 1]);
      final bounded = AssetScope(
        services: const AssetServices(
          resolver: NativeSourceResolver(),
          limits: AssetLimits(maxSourceBytes: 2),
        ),
      );
      await expectLater(
        bounded
            .load(AssetRequest(uri: file.uri, loader: const BytesLoader()))
            .result,
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      await bounded.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
