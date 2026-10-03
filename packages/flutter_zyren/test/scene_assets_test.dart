import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'controller_test.dart' show host, frames, readback;
import 'support/backend_fake.dart';
import 'support/fakes.dart';

class Resolver implements ByteSourceResolver {
  final Uint8List bytes;
  int reads = 0;
  Resolver([Uint8List? bytes]) : bytes = bytes ?? Uint8List(4);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads++;
    context.reportProgress(0);
    context.reportProgress(bytes.length, bytes.length);
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}

SceneRuntime runtime(AssetServices services) {
  final backend = FakeBackend();
  return SceneRuntime(
    assetServices: services,
    backendFactory: () async => backend,
    presenterFactory: () => TestPresenter('assets', backend.events),
  );
}

class Value {
  final Uri source;
  bool released = false;
  Value(this.source);
}

class Loader extends AssetLoader<Value> {
  int decodes = 0, cancellations = 0, releases = 0, disposals = 0;
  bool fail = false;
  final pauses = <Uri, Completer<void>>{};
  @override
  Future<DecodedAsset<Value>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    decodes++;
    context.report(
      LoadProgress(stage: LoadStage.decode, completedBytes: 2, totalBytes: 4),
    );
    final cancellation = context.cancellation.onCancel(() => cancellations++);
    try {
      await pauses[source.effectiveUri]?.future;
      if (fail) throw StateError('decode fixture');
      return DecodedAsset(
        create: () => Value(source.effectiveUri),
        release: (value) {
          value.released = true;
          releases++;
        },
        dispose: () => disposals++,
      );
    } finally {
      cancellation.dispose();
    }
  }
}

AssetRequest<Value> request(Loader loader, [String path = 'one']) =>
    AssetRequest(uri: Uri.parse('memory:/$path'), loader: loader);

class ImageDecoderFake implements ImageDecoder {
  int decodes = 0;
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    decodes++;
    return ImageData(
      size: PhysicalSize(1, 1),
      pixels: Uint8List.fromList([255, 0, 0, 255]),
    );
  }
}

class CountedModelLoader extends AssetLoader<ModelAsset> {
  int decodes = 0, releases = 0;
  final complete = Completer<void>();
  final List<ModelAsset> templates = [];
  @override
  Object get cacheKey => const GltfOptions();
  @override
  Future<DecodedAsset<ModelAsset>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    decodes++;
    final decoded = await Gltf.uri(
      source.effectiveUri,
    ).loader.decode(source, context);
    if (!complete.isCompleted) complete.complete();
    return DecodedAsset(
      create: () {
        final asset = decoded.create();
        templates.add(asset);
        return asset;
      },
      release: (asset) {
        releases++;
        decoded.release(asset);
      },
      dispose: decoded.dispose,
    );
  }
}

void main() {
  testWidgets(
    'visible progress and failure builders can retry and own the result',
    (tester) async {
      final loader = Loader()..fail = true;
      final pause = Completer<void>();
      loader.pauses[Uri.parse('memory:/one')] = pause;
      final resolver = Resolver(), cache = AssetCache();
      final sceneRuntime = runtime(AssetServices(resolver: resolver));
      Value? loaded;
      final rootRef = SceneRef<Group>();
      late SceneController controller;
      await tester.pumpWidget(
        host(
          SceneCanvas(
            runtime: sceneRuntime,
            options: readback,
            assetCache: cache,
            onCreated: (value) => controller = value,
            overlay: SceneAsset<Value>(
              request: request(loader),
              loadingBuilder: (context, progress) =>
                  Text('loading ${progress?.completedBytes}'),
              errorBuilder: (context, error, stack, retry) =>
                  GestureDetector(onTap: retry, child: const Text('retry')),
              builder: (context, value) {
                loaded = value;
                return Stack(
                  children: [
                    const Text('loaded'),
                    GroupNode(ref: rootRef),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('loading 2'), findsOneWidget);
      pause.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('retry'), findsOneWidget);
      expect(cache.length, 0);
      loader.fail = false;
      await tester.tap(find.text('retry'));
      await tester.pump();
      await tester.pump();
      expect(find.text('loaded'), findsOneWidget);
      expect(loader.decodes, 2);
      expect(loaded!.released, isFalse);
      expect(controller.scene.children, [rootRef.require]);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(loaded!.released, isTrue);
      expect(rootRef.current, isNull);
      expect(loader.releases, 1);
      expect(cache.isDisposed, isFalse);
      cache.dispose();
      expect(loader.disposals, 1);
    },
  );

  testWidgets(
    'replacement and unmount cancel late work with no attach or leaked ref',
    (tester) async {
      final loader = Loader(),
          sceneRuntime = runtime(AssetServices(resolver: Resolver()));
      final first = Completer<void>(), second = Completer<void>();
      loader.pauses[Uri.parse('memory:/one')] = first;
      loader.pauses[Uri.parse('memory:/two')] = second;
      final ref = SceneRef<Group>();
      var builds = 0;
      late SceneController controller;
      Widget scene(String path) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          onCreated: (value) => controller = value,
          children: [
            SceneAsset<Value>(
              request: request(loader, path),
              builder: (context, value) {
                builds++;
                return GroupNode(ref: ref);
              },
            ),
          ],
        ),
      );
      await tester.pumpWidget(scene('one'));
      await tester.pump();
      await tester.pumpWidget(scene('two'));
      await tester.pump();
      expect(loader.cancellations, 1);
      first.complete();
      await tester.pump();
      expect(builds, 0);
      expect(controller.scene.children, isEmpty);
      await tester.pumpWidget(const SizedBox());
      expect(loader.cancellations, 2);
      second.complete();
      await frames(tester);
      expect(loader.disposals, 2);
      expect(loader.releases, 0);
      expect(ref.current, isNull);
      expect(builds, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'equivalent fresh texture requests retain ownership and completed pixels',
    (tester) async {
      final decoder = ImageDecoderFake(), resolver = Resolver();
      final sceneRuntime = runtime(
        AssetServices(resolver: resolver, imageDecoder: decoder),
      );
      final cache = AssetCache();
      final values = <TextureImage>[];
      Widget scene(bool show, {int count = 1}) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          assetCache: cache,
          children: [
            for (var i = 0; show && i < count; i++)
              SceneAsset<TextureImage>(
                key: ValueKey(i),
                request: TextureAssets.uri(Uri.parse('memory:/texture')),
                builder: (context, value) {
                  values.add(value);
                  return const SizedBox.shrink();
                },
              ),
          ],
        ),
      );
      await tester.pumpWidget(scene(true));
      await tester.pump();
      final first = values.last;
      await tester.pumpWidget(scene(true));
      await tester.pump();
      expect(values.last, same(first));
      expect(decoder.decodes, 1);
      await tester.pumpWidget(scene(false));
      await tester.pumpWidget(scene(true, count: 2));
      await tester.pump();
      final second = values[values.length - 2], third = values.last;
      expect(second, isNot(same(third)));
      expect(second, isNot(same(first)));
      expect(second.data, same(first.data));
      expect(third.data, same(first.data));
      expect(resolver.reads, 1);
      expect(decoder.decodes, 1);
      cache.clear();
      expect(first.levels.first, [255, 0, 0, 255]);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      cache.dispose();
    },
  );

  testWidgets(
    'async real glTF mounts fresh models and child builders under each root',
    (tester) async {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'asset': {'version': '2.0'},
            'scene': 0,
            'scenes': [
              {
                'nodes': [0],
              },
            ],
            'nodes': [
              {'name': 'root'},
            ],
          }),
        ),
      );
      final resolver = Resolver(bytes), loader = CountedModelLoader();
      final sceneRuntime = runtime(AssetServices(resolver: resolver));
      final refs = [SceneRef<ModelInstance>(), SceneRef<ModelInstance>()];
      final childRefs = [SceneRef<Group>(), SceneRef<Group>()];
      AssetCache? canvasCache;
      Widget scene(bool show) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          children: [
            for (var i = 0; show && i < 2; i++)
              ModelNode(
                key: ValueKey(i),
                request: AssetRequest(
                  uri: Uri.parse('memory:/scene.gltf'),
                  loader: loader,
                ),
                ref: refs[i],
                builder: (context, instance) => GroupNode(ref: childRefs[i]),
              ),
          ],
          overlay: Builder(
            builder: (context) {
              canvasCache = SceneScope.assetCacheOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpWidget(scene(true));
      for (
        var attempt = 0;
        attempt < 100 && !loader.complete.isCompleted;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(loader.complete.isCompleted, isTrue);
      await tester.pump();
      await tester.pump();
      expect(refs[0].current, isNotNull);
      expect(refs[1].current, isNotNull);
      final first = refs[0].require, second = refs[1].require;
      expect(first, isNot(same(second)));
      expect(first.nodes[0], isNot(same(second.nodes[0])));
      expect(childRefs[0].require.parent, same(first));
      expect(childRefs[1].require.parent, same(second));
      first.position = const Vec3(8, 0, 0);
      expect(second.position, Vec3.zero);
      await tester.pumpWidget(scene(true));
      expect(refs[0].require, same(first));
      expect(loader.decodes, 1);
      expect(resolver.reads, 1);
      await tester.pumpWidget(scene(false));
      expect(refs.every((ref) => ref.current == null), isTrue);
      expect(first.parent, isNull);
      expect(second.parent, isNull);
      expect(loader.templates.every((asset) => asset.isReleased), isTrue);
      expect(first.nodes[0]!.name, 'root');
      await tester.pumpWidget(scene(true));
      await tester.pump();
      expect(refs[0].require, isNot(same(first)));
      expect(loader.decodes, 1);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(canvasCache!.isDisposed, isTrue);
      expect(loader.releases, 4);
      expect(tester.takeException(), isNull);
    },
  );
}
