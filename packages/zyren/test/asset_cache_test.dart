import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'shared_load_test.dart' show ModelLoader, Template;

class Resolver implements ByteSourceResolver {
  int reads = 0;
  bool fail = false;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads++;
    if (fail) throw StateError('failed read');
    return ResolvedSource(effectiveUri: uri, bytes: Uint8List(4));
  }
}

class SizedLoader extends ModelLoader {
  final int bytes;
  SizedLoader(this.bytes);
  @override
  Future<DecodedAsset<Template>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) {
    context.reserveDecodedBytes(bytes);
    return super.decode(source, context);
  }
}

class FailingFactoryLoader extends ModelLoader {
  bool failCreate = false;
  @override
  Future<DecodedAsset<Template>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final decoded = await super.decode(source, context);
    return DecodedAsset(
      create: () {
        if (failCreate) throw StateError('factory fixture');
        return decoded.create();
      },
      release: decoded.release,
      dispose: decoded.dispose,
    );
  }
}

AssetRequest<Template> request(
  ModelLoader loader, [
  String path = 'one',
  String? version,
]) => AssetRequest(
  uri: Uri.parse('memory:/$path'),
  loader: loader,
  version: version,
);

void main() {
  test(
    'completed cache shares recipes with fresh scope-owned results',
    () async {
      final loader = SizedLoader(8), resolver = Resolver();
      final services = AssetServices(resolver: resolver);
      final cache = AssetCache();
      final a = AssetScope(services: services, cache: cache);
      final first = await a.load(request(loader)).result;
      await a.close();
      expect(first.released, isTrue);
      expect(loader.disposals, 0);
      final b = AssetScope(services: services, cache: cache);
      final second = await b.load(request(loader)).result;
      expect(second, isNot(same(first)));
      expect(second.shared, same(first.shared));
      expect(cache.length, 1);
      expect(cache.decodedBytes, 8);
      expect(resolver.reads, 1);
      cache.clear();
      expect(loader.disposals, 1);
      expect(second.instantiate(), isNotNull);
      await b.close();
      expect(loader.releases, 2);
      cache.dispose();
      expect(loader.disposals, 1);
    },
  );

  test('LRU respects entry and decoded byte bounds', () async {
    final loader = SizedLoader(4), resolver = Resolver();
    final services = AssetServices(resolver: resolver);
    final cache = AssetCache(maxEntries: 2, maxDecodedBytes: 8);
    final scope = AssetScope(services: services, cache: cache);
    await scope.load(request(loader, 'a')).result;
    await scope.load(request(loader, 'b')).result;
    await scope.load(request(loader, 'a')).result;
    await scope.load(request(loader, 'c')).result;
    expect(loader.disposals, 1);
    await scope.load(request(loader, 'a')).result;
    expect(resolver.reads, 3);
    await scope.load(request(loader, 'b')).result;
    expect(resolver.reads, 4);
    expect(cache.length, 2);
    expect(cache.decodedBytes, 8);
    cache.dispose();
    expect(loader.disposals, 4);
    await scope.close();
    final byteCache = AssetCache(maxEntries: 9, maxDecodedBytes: 5);
    final byteScope = AssetScope(services: services, cache: byteCache);
    await byteScope.load(request(loader, 'a')).result;
    await byteScope.load(request(loader, 'b')).result;
    expect(byteCache.length, 1);
    expect(byteCache.decodedBytes, 4);
    final huge = SizedLoader(6);
    await byteScope.load(request(huge)).result;
    expect(huge.disposals, 1);
    expect(byteCache.length, 1);
    byteCache.dispose();
    await byteScope.close();
  });

  test('cache identity isolates services, URI, version and loader', () async {
    final loader = SizedLoader(4),
        resolver = Resolver(),
        otherLoader = SizedLoader(4);
    final services = AssetServices(resolver: resolver),
        other = AssetServices(resolver: resolver);
    final cache = AssetCache();
    final a = AssetScope(services: services, cache: cache),
        b = AssetScope(services: other, cache: cache);
    await a.load(request(loader)).result;
    await a.load(request(loader)).result;
    await a.load(request(loader, 'one', 'v2')).result;
    await a.load(request(loader, 'two')).result;
    await a.load(request(otherLoader)).result;
    await b.load(request(loader)).result;
    expect(resolver.reads, 5);
    expect(cache.length, 5);
    cache.evict(services, request(loader));
    await a.load(request(loader)).result;
    expect(resolver.reads, 6);
    await a.close();
    await b.close();
    cache.dispose();
  });

  test('clear and dispose during decode forbid late cache admission', () async {
    for (final dispose in [false, true]) {
      final loader = SizedLoader(4)..pause = Completer<void>();
      final services = AssetServices(resolver: Resolver());
      final cache = AssetCache();
      final scope = AssetScope(services: services, cache: cache);
      final task = scope.load(request(loader));
      await loader.decoded.future;
      if (dispose) {
        cache.dispose();
      } else {
        cache.clear();
      }
      loader.pause!.complete();
      final value = await task.result;
      expect(value.released, isFalse);
      expect(cache.length, 0);
      expect(loader.disposals, 1);
      await scope.close();
      cache.dispose();
    }
  });

  test(
    'cached delivery survives eviction and immediate cancellation releases its hold',
    () async {
      final loader = SizedLoader(4),
          services = AssetServices(resolver: Resolver());
      final cache = AssetCache();
      final scope = AssetScope(services: services, cache: cache);
      await scope.load(request(loader)).result;
      final hit = scope.load(request(loader));
      cache.clear();
      expect(loader.disposals, 0);
      final value = await hit.result;
      expect(loader.disposals, 1);
      expect(value.instantiate(), isNotNull);
      await scope.load(request(loader)).result;
      final cancelled = scope.load(request(loader));
      cancelled.cancel();
      cache.clear();
      await expectLater(cancelled.result, throwsA(isA<LoadCancelled>()));
      await Future<void>.delayed(Duration.zero);
      expect(loader.disposals, 2);
      await scope.close();
      cache.dispose();
    },
  );

  test(
    'simultaneous caches share decode and hold recipes independently',
    () async {
      final loader = SizedLoader(4),
          services = AssetServices(resolver: Resolver());
      final firstCache = AssetCache(), secondCache = AssetCache();
      final a = AssetScope(services: services, cache: firstCache),
          b = AssetScope(services: services, cache: secondCache);
      await Future.wait([
        a.load(request(loader)).result,
        b.load(request(loader)).result,
      ]);
      expect(loader.decodes, 1);
      firstCache.dispose();
      expect(loader.disposals, 0);
      secondCache.dispose();
      expect(loader.disposals, 1);
      await a.close();
      await b.close();
    },
  );

  test('result types isolate recipes and semantic request equality', () async {
    final loader = ModelLoader(), resolver = Resolver();
    final cache = AssetCache();
    final scope = AssetScope(
      services: AssetServices(resolver: resolver),
      cache: cache,
    );
    final typed = request(loader);
    final widened = AssetRequest<Object>(uri: typed.uri, loader: loader);
    expect(typed, request(loader));
    expect(typed.hashCode, request(loader).hashCode);
    expect(widened == typed, isFalse);
    expect(typed == widened, isFalse);
    await scope.load(typed).result;
    await scope.load(widened).result;
    expect(resolver.reads, 2);
    expect(cache.length, 2);
    await scope.close();
    cache.dispose();
  });

  test(
    'last scoped cancellation during cached decode disposes late recipe once',
    () async {
      final loader = ModelLoader()..pause = Completer<void>();
      final cache = AssetCache();
      final services = AssetServices(resolver: Resolver());
      final a = AssetScope(services: services, cache: cache),
          b = AssetScope(services: services, cache: cache);
      final first = a.load(request(loader)), second = b.load(request(loader));
      final progress = second.progress.toList();
      await loader.decoded.future;
      await a.close();
      expect(cache.length, 0);
      await b.close();
      await expectLater(first.result, throwsA(isA<LoadCancelled>()));
      await expectLater(second.result, throwsA(isA<LoadCancelled>()));
      await progress;
      loader.pause!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(loader.disposals, 1);
      expect(loader.releases, 0);
      expect(cache.length, 0);
      cache.dispose();
      expect(loader.disposals, 1);
    },
  );

  test('failed result factories are removed and retry decodes again', () async {
    final loader = FailingFactoryLoader()..failCreate = true;
    final cache = AssetCache();
    final scope = AssetScope(
      services: AssetServices(resolver: Resolver()),
      cache: cache,
    );
    await expectLater(
      scope.load(request(loader)).result,
      throwsA(isA<AssetLoadException>()),
    );
    expect(cache.length, 0);
    expect(loader.disposals, 1);
    loader.failCreate = false;
    await scope.load(request(loader)).result;
    loader.failCreate = true;
    await expectLater(
      scope.load(request(loader)).result,
      throwsA(isA<AssetLoadException>()),
    );
    expect(cache.length, 0);
    expect(loader.disposals, 2);
    loader.failCreate = false;
    await scope.load(request(loader)).result;
    expect(loader.decodes, 3);
    await scope.close();
    cache.dispose();
  });

  test('failed work is retried and disposed caches reject new work', () async {
    final resolver = Resolver()..fail = true;
    final loader = SizedLoader(4), cache = AssetCache();
    final scope = AssetScope(
      services: AssetServices(resolver: resolver),
      cache: cache,
    );
    await expectLater(
      scope.load(request(loader)).result,
      throwsA(isA<AssetLoadException>()),
    );
    expect(cache.length, 0);
    resolver.fail = false;
    await scope.load(request(loader)).result;
    expect(resolver.reads, 2);
    cache.dispose();
    expect(() => scope.load(request(loader)), throwsStateError);
    await scope.close();
    expect(() => AssetCache(maxEntries: 0), throwsRangeError);
  });
}
