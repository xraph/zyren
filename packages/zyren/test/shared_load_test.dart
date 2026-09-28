import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

final sourceUri = Uri.parse('memory:/model');

class MemoryResolver implements ByteSourceResolver {
  final started = Completer<void>();
  final bytes = Completer<Uint8List>();
  int reads = 0, cancellations = 0;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads++;
    if (!started.isCompleted) started.complete();
    final registration = context.cancellation.onCancel(() => cancellations++);
    try {
      context.reportProgress(0);
      final data = await bytes.future;
      context.reportProgress(data.length, data.length);
      return ResolvedSource(effectiveUri: uri, bytes: data);
    } finally {
      registration.dispose();
    }
  }
}

class Template {
  final Object shared;
  bool released = false;
  Template(this.shared);
  Object instantiate() {
    if (released) throw StateError('Template was released.');
    return shared;
  }
}

class ModelLoader extends AssetLoader<Template> {
  int decodes = 0, releases = 0, disposals = 0;
  final decoded = Completer<void>();
  Completer<void>? pause;
  @override
  Future<DecodedAsset<Template>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    decodes++;
    if (!decoded.isCompleted) decoded.complete();
    await pause?.future;
    final shared = Object();
    return DecodedAsset(
      create: () => Template(shared),
      release: (value) {
        value.released = true;
        releases++;
      },
      dispose: () => disposals++,
    );
  }
}

void main() {
  late MemoryResolver resolver;
  late ModelLoader loader;
  late AssetServices services;
  late AssetRequest<Template> request;
  setUp(() {
    resolver = MemoryResolver();
    loader = ModelLoader();
    services = AssetServices(resolver: resolver);
    request = AssetRequest(uri: sourceUri, loader: loader);
  });

  test('immediate cancellation starts no source work', () async {
    final scope = AssetScope(services: services);
    final task = scope.load(request);
    task.cancel();
    await expectLater(task.result, throwsA(isA<LoadCancelled>()));
    await Future<void>.delayed(Duration.zero);
    expect(resolver.reads, 0);
    expect(loader.decodes, 0);
    await scope.close();
  });

  test(
    'one cancelled consumer leaves a shared fetch and decode alive',
    () async {
      final firstScope = AssetScope(services: services);
      final secondScope = AssetScope(services: services);
      final first = firstScope.load(request);
      final second = secondScope.load(request);
      final firstProgress = first.progress.toList();
      final secondProgress = second.progress.toList();
      await resolver.started.future;
      final cancelled = expectLater(
        first.result,
        throwsA(isA<LoadCancelled>()),
      );
      first.cancel();
      first.cancel();
      resolver.bytes.complete(Uint8List(4));
      await cancelled;
      final model = await second.result;
      expect(resolver.reads, 1);
      expect(resolver.cancellations, 0);
      expect(loader.decodes, 1);
      expect(loader.disposals, 1);
      expect(model.instantiate(), isNotNull);
      expect(await firstProgress, isNotEmpty);
      expect((await secondProgress).first.totalBytes, isNull);
      await firstScope.close();
      expect(model.released, isFalse);
      await secondScope.close();
      expect(model.released, isTrue);
      expect(loader.releases, 1);
    },
  );

  test(
    'each scope gets a separate template over shared decoded data',
    () async {
      final a = AssetScope(services: services),
          b = AssetScope(services: services);
      final first = a.load(request), second = b.load(request);
      resolver.bytes.complete(Uint8List(4));
      final models = await Future.wait([first.result, second.result]);
      expect(identical(models[0], models[1]), isFalse);
      final instance = models[0].instantiate();
      expect(identical(instance, models[1].instantiate()), isTrue);
      a.release(models[0]);
      a.release(models[0]);
      expect(models[0].instantiate, throwsStateError);
      expect(models[1].instantiate(), same(instance));
      first.cancel();
      expect(await first.result, same(models[0]));
      await a.close();
      await b.close();
      expect(loader.releases, 2);
    },
  );

  test('last cancellation aborts once and allows an immediate retry', () async {
    final scope = AssetScope(services: services);
    final first = scope.load(request), second = scope.load(request);
    await resolver.started.future;
    first.cancel();
    second.cancel();
    expect(resolver.cancellations, 1);
    final retry = scope.load(request);
    resolver.bytes.complete(Uint8List(4));
    await expectLater(first.result, throwsA(isA<LoadCancelled>()));
    await expectLater(second.result, throwsA(isA<LoadCancelled>()));
    await retry.result;
    expect(resolver.reads, 2);
    expect(loader.decodes, 1);
    await scope.close();
  });

  test(
    'closing during decode discards late ownership and settles progress',
    () async {
      loader.pause = Completer<void>();
      final scope = AssetScope(services: services);
      final task = scope.load(request);
      final progress = task.progress.toList();
      resolver.bytes.complete(Uint8List(4));
      await loader.decoded.future;
      await scope.close();
      await expectLater(task.result, throwsA(isA<LoadCancelled>()));
      await progress;
      loader.pause!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(loader.disposals, 1);
      expect(loader.releases, 0);
      expect(() => scope.load(request), throwsStateError);
    },
  );

  test(
    'source/version/options and service identity isolate in-flight jobs',
    () async {
      final scope = AssetScope(services: services);
      final otherLoader = ModelLoader();
      final otherScope = AssetScope(
        services: AssetServices(resolver: resolver),
      );
      final tasks = [
        scope.load(request),
        scope.load(AssetRequest(uri: sourceUri, loader: loader, version: 'v2')),
        scope.load(AssetRequest(uri: sourceUri, loader: otherLoader)),
        scope.load(
          AssetRequest(uri: Uri.parse('memory:/other'), loader: loader),
        ),
        otherScope.load(request),
      ];
      resolver.bytes.complete(Uint8List(4));
      await Future.wait(tasks.map((task) => task.result));
      expect(resolver.reads, 5);
      expect(loader.decodes, 4);
      await scope.load(request).result;
      expect(
        resolver.reads,
        6,
        reason: 'completed mutable URIs are not cached',
      );
      await scope.close();
      await otherScope.close();
    },
  );

  test(
    'resolver failures settle all consumers, close streams and permit retry',
    () async {
      final scope = AssetScope(services: services);
      final task = scope.load(request);
      final progress = task.progress.toList();
      final result = expectLater(
        task.result,
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.sourceFailed,
          ),
        ),
      );
      await resolver.started.future;
      resolver.bytes.completeError(StateError('read failed'));
      await result;
      await progress;
      expect(loader.decodes, 0);
      await scope.close();
    },
  );
}
