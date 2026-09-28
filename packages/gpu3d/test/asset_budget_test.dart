import 'dart:async';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

class Resolver implements ByteSourceResolver {
  final Future<ResolvedSource> Function(Uri, SourceReadContext) run;
  Resolver(this.run);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) =>
      run(uri, context);
}

class Loader extends AssetLoader<Object> {
  final Future<DecodedAsset<Object>> Function(
    ResolvedSource,
    AssetDecodeContext,
  )
  run;
  Loader(this.run);
  @override
  Future<DecodedAsset<Object>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) => run(source, context);
}

class Decoder implements ImageDecoder {
  final List<int> remaining = [];
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    remaining.add(limits.maxDecodedBytes);
    return ImageData(pixels: Uint8List(4), size: PhysicalSize(1, 1));
  }
}

final root = Uri.parse('https://models.test/start');
DecodedAsset<Object> objectAsset() =>
    DecodedAsset(create: Object.new, release: (_) {});
TypeMatcher<AssetLoadException> loadError(AssetLoadError code) =>
    isA<AssetLoadException>().having((e) => e.code, 'code', code);

void main() {
  test('decoder failure aborts a dependency that is still reading', () async {
    final entered = Completer<void>(), aborted = Completer<void>();
    final pending = Completer<ResolvedSource>();
    final resolver = Resolver((uri, context) async {
      if (uri == root) {
        return ResolvedSource(effectiveUri: uri, bytes: Uint8List(1));
      }
      final registration = context.cancellation.onCancel(() {
        aborted.complete();
        pending.completeError(LoadCancelled());
      });
      entered.complete();
      try {
        return await pending.future;
      } finally {
        registration.dispose();
      }
    });
    final scope = AssetScope(services: AssetServices(resolver: resolver));
    final loader = Loader((source, context) async {
      unawaited(
        context
            .readReference('pending', relativeTo: root)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      await entered.future;
      throw StateError('decoding failed while a dependency was pending');
    });
    await expectLater(
      scope.load(AssetRequest(uri: root, loader: loader)).result,
      throwsA(loadError(AssetLoadError.decodeFailed)),
    );
    await aborted.future.timeout(const Duration(seconds: 1));
    await scope.close();
  });

  test('reentrant close returns the same completion future', () async {
    final resolver = Resolver(
      (uri, context) async =>
          ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
    );
    final scope = AssetScope(services: AssetServices(resolver: resolver));
    Future<void>? reentrant;
    final loader = Loader(
      (source, context) async => DecodedAsset(
        create: Object.new,
        release: (_) => reentrant = scope.close(),
      ),
    );
    await scope.load(AssetRequest(uri: root, loader: loader)).result;
    final closing = scope.close();
    expect(reentrant, same(closing));
    await closing;
  });

  test('one result factory failure leaves the next consumer usable', () async {
    var creations = 0, disposals = 0;
    final resolver = Resolver(
      (uri, context) async =>
          ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
    );
    final scope = AssetScope(services: AssetServices(resolver: resolver));
    final loader = Loader(
      (source, context) async => DecodedAsset(
        create: () {
          if (creations++ == 0) throw StateError('factory');
          return Object();
        },
        release: (_) {},
        dispose: () => disposals++,
      ),
    );
    final request = AssetRequest(uri: root, loader: loader);
    final first = scope.load(request), second = scope.load(request);
    await expectLater(
      first.result,
      throwsA(loadError(AssetLoadError.decodeFailed)),
    );
    expect(await second.result, isNotNull);
    expect(disposals, 1);
    await scope.close();
  });

  test(
    'late release failures reach the cleanup callback after cancellation',
    () async {
      final errors = <Object>[];
      final resolver = Resolver(
        (uri, context) async =>
            ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
      );
      final scope = AssetScope(
        services: AssetServices(resolver: resolver, onCleanupError: errors.add),
      );
      final loader = Loader(
        (source, context) async => DecodedAsset(
          create: () {
            unawaited(scope.close());
            return Object();
          },
          release: (_) => throw StateError('late release'),
        ),
      );
      await expectLater(
        scope.load(AssetRequest(uri: root, loader: loader)).result,
        throwsA(isA<LoadCancelled>()),
      );
      expect(errors, hasLength(1));
    },
  );

  test(
    'relative references use the effective base and share one dependency read',
    () async {
      final reads = <Uri>[];
      final effective = Uri.parse('https://models.test/models/part/model.gltf');
      final resolver = Resolver((uri, context) async {
        reads.add(uri);
        return ResolvedSource(
          effectiveUri: uri == root ? effective : uri,
          bytes: Uint8List(2),
        );
      });
      final scope = AssetScope(services: AssetServices(resolver: resolver));
      final loader = Loader((source, context) async {
        final references = await Future.wait([
          context.readReference('../mesh.bin', relativeTo: source.effectiveUri),
          context.readReference('../mesh.bin', relativeTo: source.effectiveUri),
        ]);
        expect(references[0], same(references[1]));
        expect(context.encodedBytes, 4);
        return objectAsset();
      });
      await scope.load(AssetRequest(uri: root, loader: loader)).result;
      expect(reads, [root, Uri.parse('https://models.test/models/mesh.bin')]);
      await scope.close();
    },
  );

  test(
    'queued dependencies spend the remaining aggregate budget once',
    () async {
      final admitted = <int>[];
      final resolver = Resolver((uri, context) async {
        admitted.add(context.maxBytes);
        return ResolvedSource(effectiveUri: uri, bytes: Uint8List(4));
      });
      final scope = AssetScope(
        services: AssetServices(
          resolver: resolver,
          limits: const AssetLimits(maxSourceBytes: 5, maxTotalSourceBytes: 10),
        ),
      );
      final loader = Loader((source, context) async {
        await Future.wait([
          context.readReference('a', relativeTo: root),
          context.readReference('b', relativeTo: root),
        ]);
        return objectAsset();
      });
      await expectLater(
        scope.load(AssetRequest(uri: root, loader: loader)).result,
        throwsA(loadError(AssetLoadError.limitExceeded)),
      );
      expect(admitted, [5, 5, 2]);
      await scope.close();
    },
  );

  test(
    'source count limits reject queued dependencies before fetching',
    () async {
      var reads = 0;
      final resolver = Resolver((uri, context) async {
        reads++;
        return ResolvedSource(effectiveUri: uri, bytes: Uint8List(1));
      });
      final scope = AssetScope(
        services: AssetServices(
          resolver: resolver,
          limits: const AssetLimits(maxSources: 1),
        ),
      );
      final loader = Loader((source, context) async {
        await context.readReference(
          'part',
          relativeTo: root,
          fieldPath: 'buffers[0].uri',
        );
        return objectAsset();
      });
      await expectLater(
        scope.load(AssetRequest(uri: root, loader: loader)).result,
        throwsA(
          loadError(
            AssetLoadError.limitExceeded,
          ).having((e) => e.fieldPath, 'field', 'buffers[0].uri'),
        ),
      );
      expect(reads, 1);
      await scope.close();
    },
  );

  test('bundle references cannot switch to files or remote hosts', () async {
    final uri = Uri.parse('asset:///models/model.gltf');
    final resolver = Resolver(
      (uri, context) async =>
          ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
    );
    for (final reference in [
      'file:///private/other.bin',
      'https://models.test/other.bin',
      '//other/part.bin',
    ]) {
      final scope = AssetScope(services: AssetServices(resolver: resolver));
      final loader = Loader((source, context) async {
        await context.readReference(
          reference,
          relativeTo: uri,
          fieldPath: 'buffers[0].uri',
        );
        return objectAsset();
      });
      await expectLater(
        scope.load(AssetRequest(uri: uri, loader: loader)).result,
        throwsA(loadError(AssetLoadError.forbiddenReference)),
      );
      await scope.close();
    }
  });

  test(
    'concurrent image decodes share remaining decoded bytes with geometry',
    () async {
      final decoder = Decoder();
      final resolver = Resolver(
        (uri, context) async =>
            ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
      );
      final scope = AssetScope(
        services: AssetServices(
          resolver: resolver,
          imageDecoder: decoder,
          limits: const AssetLimits(maxDecodedBytes: 11),
        ),
      );
      final loader = Loader((source, context) async {
        context.reserveDecodedBytes(4, fieldPath: 'meshes[0]');
        await Future.wait([
          context.decodeImage(Uint8List(1), fieldPath: 'images[0]'),
          context.decodeImage(Uint8List(1), fieldPath: 'images[1]'),
        ]);
        return objectAsset();
      });
      await expectLater(
        scope.load(AssetRequest(uri: root, loader: loader)).result,
        throwsA(
          loadError(
            AssetLoadError.limitExceeded,
          ).having((e) => e.fieldPath, 'field', 'images[1]'),
        ),
      );
      expect(decoder.remaining, [7, 3]);
      await scope.close();
    },
  );

  test('cleanup runs for all held assets and reports failures once', () async {
    var releases = 0, disposals = 0;
    final cleanupErrors = <Object>[];
    final resolver = Resolver(
      (uri, context) async =>
          ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
    );
    final scope = AssetScope(
      services: AssetServices(
        resolver: resolver,
        onCleanupError: cleanupErrors.add,
      ),
    );
    final loader = Loader(
      (source, context) async => DecodedAsset(
        create: Object.new,
        release: (_) {
          releases++;
          throw StateError('release');
        },
        dispose: () {
          disposals++;
          throw StateError('dispose');
        },
      ),
    );
    final request = AssetRequest(uri: root, loader: loader);
    await Future.wait([scope.load(request).result, scope.load(request).result]);
    expect(disposals, 1);
    expect(cleanupErrors, hasLength(1));
    final closing = scope.close();
    await expectLater(closing, throwsA(isA<ScopeCleanupException>()));
    expect(scope.close(), same(closing));
    expect(releases, 2);
  });

  test(
    'factory reentrancy cancels publication and releases its new value',
    () async {
      var releases = 0, disposed = 0;
      final resolver = Resolver(
        (uri, context) async =>
            ResolvedSource(effectiveUri: uri, bytes: Uint8List(1)),
      );
      final scope = AssetScope(services: AssetServices(resolver: resolver));
      final loader = Loader(
        (source, context) async => DecodedAsset(
          create: () {
            unawaited(scope.close());
            return Object();
          },
          release: (_) => releases++,
          dispose: () => disposed++,
        ),
      );
      await expectLater(
        scope.load(AssetRequest(uri: root, loader: loader)).result,
        throwsA(isA<LoadCancelled>()),
      );
      expect(releases, 1);
      expect(disposed, 1);
    },
  );
}
