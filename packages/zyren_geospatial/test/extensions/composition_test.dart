import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

class _Renderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities =>
      RendererCapabilities(name: 'test', features: {}, maxDimension: 64);
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}

class _Extension extends GeospatialExtension {
  @override
  final String localId;
  @override
  final int contractVersion;
  final Set<String> requires;
  final FutureOr<void> Function(GeospatialContext)? onAttach, onDetach;
  GeospatialContext? attached;
  _Extension(
    this.localId, {
    this.contractVersion = 1,
    this.requires = const {},
    this.onAttach,
    this.onDetach,
  });
  @override
  Set<String> get dependencies => {GeospatialPlugin.pluginId, ...requires};
  @override
  FutureOr<void> attachGeospatial(GeospatialContext context) {
    attached = context;
    return onAttach?.call(context);
  }

  @override
  FutureOr<void> detachGeospatial(GeospatialContext context) =>
      onDetach?.call(context);
}

class _Adapter extends ScenePlugin {
  @override
  final String id;
  @override
  final Set<String> dependencies;
  PluginContext? context;
  _Adapter(this.id, this.dependencies);
  @override
  void attach(PluginContext context) => this.context = context;
}

class _Wrapped extends _Extension {
  late final _Adapter adapter = _Adapter('$id.renderer', {id});
  _Wrapped() : super('wrapped');
  @override
  List<ScenePlugin> get adapters => [adapter];
  @override
  Set<String> get incompatiblePluginIds => {'legacy.renderer'};
}

Future<SceneEngine> create(
  List<ScenePlugin> plugins, {
  AttachmentScope? lifetime,
}) => SceneEngine.create(
  scene: Scene(),
  camera: PerspectiveCamera(),
  plugins: plugins,
  lifetime: lifetime,
  rendererFactory: () async => _Renderer(),
);

void main() {
  test(
    'adapters require expansion, identity and compatible legacy composition',
    () async {
      final extension = _Wrapped();
      final geo = GeospatialPlugin(extensions: [extension]);
      await expectLater(create([geo, extension]), throwsStateError);
      await expectLater(
        create([...geo.scenePlugins, _Adapter('legacy.renderer', {})]),
        throwsStateError,
      );
      final engine = await create(geo.scenePlugins);
      expect(
        extension.adapter.context,
        isNot(same(extension.attached!.sceneContext)),
      );
      await engine.dispose();
    },
  );

  test(
    'cleanup errors do not leave registry entries or prevent other detach',
    () async {
      final geo = GeospatialPlugin();
      final broken = _Extension(
        'broken',
        onAttach: (c) {
          c.sceneContext.scope.keep(
            Registration(() => throw StateError('cleanup')),
          );
        },
      );
      final stable = _Extension('stable');
      final engine = await create([geo, broken, stable]);
      await expectLater(
        engine.dispose(),
        throwsA(isA<EngineCleanupException>()),
      );
      expect(geo.registry.snapshot, isEmpty);
      final restarted = await create([geo, stable]);
      await restarted.dispose();
    },
  );

  test('an unexpanded configured host never allocates a renderer', () async {
    var allocated = false;
    final geo = GeospatialPlugin(extensions: [_Extension('empty')]);
    await expectLater(
      SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        plugins: [geo],
        rendererFactory: () async {
          allocated = true;
          throw StateError('renderer must not be created');
        },
      ),
      throwsStateError,
    );
    expect(allocated, isFalse);
  });

  test('expansion is stable, immutable and independently scoped', () async {
    final events = <String>[];
    final a = _Extension(
      'a',
      onAttach: (c) {
        c.sceneContext.scope.keep(Registration(() => events.add('a.close')));
      },
      onDetach: (_) => events.add('a.detach'),
    );
    final b = _Extension(
      'b',
      requires: {a.id},
      onAttach: (c) {
        c.sceneContext.scope.keep(Registration(() => events.add('b.close')));
      },
      onDetach: (_) => events.add('b.detach'),
    );
    final input = <GeospatialExtension>[b, a];
    final geo = GeospatialPlugin(extensions: input);
    input.clear();
    expect(geo.scenePlugins, same(geo.scenePlugins));
    expect(() => geo.scenePlugins.clear(), throwsUnsupportedError);
    final engine = await create(geo.scenePlugins);
    expect(a.attached!.sceneContext, isNot(same(b.attached!.sceneContext)));
    expect(a.attached!.reference, same(geo.reference));
    expect(geo.registry.snapshot.map((e) => e.id), [a.id, b.id]);
    expect(
      geo.registry.snapshot.every((e) => e.state == GeoExtensionState.attached),
      isTrue,
    );
    await engine.dispose();
    expect(events, ['b.close', 'a.close', 'b.detach', 'a.detach']);
    expect(geo.registry.snapshot, isEmpty);
    final restarted = await create(geo.scenePlugins);
    expect(geo.registry.snapshot, hasLength(2));
    await restarted.dispose();
  });

  test('invalid IDs, versions, identity, duplicates and cycles fail', () async {
    for (final extension in [
      _Extension('a.b'),
      _Extension('a/b'),
      _Extension(''),
      _Extension('v2', contractVersion: 2),
    ]) {
      await expectLater(
        Future.sync(
          () => create(GeospatialPlugin(extensions: [extension]).scenePlugins),
        ),
        throwsArgumentError,
      );
    }
    final declared = _Extension('a');
    final geo = GeospatialPlugin(extensions: [declared]);
    await expectLater(create([geo, _Extension('a')]), throwsStateError);
    await expectLater(create([geo, declared, declared]), throwsArgumentError);
    final cycle = GeospatialPlugin(
      extensions: [
        _Extension('a', requires: {'geospatial.ext.b'}),
        _Extension('b', requires: {'geospatial.ext.a'}),
      ],
    );
    await expectLater(
      create(cycle.scenePlugins),
      throwsA(isA<SceneException>()),
    );
    await expectLater(
      create([_Extension('orphan')]),
      throwsA(isA<SceneException>()),
    );
  });

  test(
    'optional provider loss is observable without detaching consumer',
    () async {
      const key = GeoServiceKey<String>('weather', 1);
      final geo = GeospatialPlugin();
      final changes = <GeoCapabilityChange>[];
      final subscription = geo.registry.capabilityChanges.listen(changes.add);
      final provider = _Extension(
        'provider',
        onAttach: (c) => c.provide(key, 'sunny'),
      );
      final consumer = _Extension('consumer');
      final engine = await create([geo, provider, consumer]);
      final original = consumer.attached;
      expect(
        consumer.attached!.find(const GeoServiceKey<String>('weather', 1)),
        'sunny',
      );
      await engine.updatePlugins([geo, consumer]);
      await Future<void>.delayed(Duration.zero);
      expect(consumer.attached, same(original));
      expect(consumer.attached!.find(key), isNull);
      expect(changes.map((e) => e.available), [true, false]);
      expect(() => provider.attached!.provide(key, 'late'), throwsStateError);
      await engine.dispose();
      await subscription.cancel();
    },
  );

  test(
    'failed update removes only owned services and reports survivors',
    () async {
      const key = GeoServiceKey<String>('weather', 1);
      final geo = GeospatialPlugin();
      final stable = _Extension(
        'stable',
        onAttach: (c) => c.provide(key, 'sunny'),
      );
      final bad = _Extension('bad', onAttach: (c) => c.provide(key, 'rain'));
      final engine = await create([geo, stable]);
      await expectLater(
        engine.updatePlugins([geo, stable, bad]),
        throwsA(
          isA<PluginUpdateException>().having(
            (e) => e.activePluginIds,
            'survivors',
            ['geospatial', stable.id],
          ),
        ),
      );
      expect(geo.registry.snapshot.map((e) => e.id), [stable.id]);
      expect(geo.registry.find(key), 'sunny');
      await engine.dispose();
      expect(geo.registry.find(key), isNull);
    },
  );

  test(
    'cancellation withdraws providers during an asynchronous attach',
    () async {
      const key = GeoServiceKey<String>('pending', 1);
      final entered = Completer<void>(), gate = Completer<void>();
      final geo = GeospatialPlugin();
      final lifetime = AttachmentScope();
      final slow = _Extension(
        'slow',
        onAttach: (c) async {
          c.provide(key, 'pending');
          entered.complete();
          await gate.future;
        },
      );
      final pending = create([geo, slow], lifetime: lifetime);
      final failed = expectLater(pending, throwsA(isA<SceneException>()));
      await entered.future;
      lifetime.close();
      expect(geo.registry.find(key), isNull);
      expect(geo.registry.snapshot, isEmpty);
      gate.complete();
      await failed;
      await lifetime.whenClosed;
    },
  );

  test(
    'typed service versions reject collisions and disposed tokens are inert',
    () {
      final registry = GeoExtensionRegistry();
      const key = GeoServiceKey<String>('weather', 1);
      final first = registry.provide(key, 'sunny');
      expect(
        () => registry.provide(const GeoServiceKey<int>('weather', 1), 1),
        throwsStateError,
      );
      expect(
        () => registry.find(const GeoServiceKey<int>('weather', 1)),
        throwsStateError,
      );
      expect(registry.find(const GeoServiceKey<String>('weather', 2)), isNull);
      first.dispose();
      final second = registry.provide(key, 'rain');
      first.dispose();
      expect(registry.find(key), 'rain');
      second.dispose();
      final old = registry.beginAttach('a', 1);
      old.dispose();
      final current = registry.beginAttach('a', 1);
      old.dispose();
      registry.markAttached('a');
      expect(registry.snapshot.single.state, GeoExtensionState.attached);
      current.dispose();
    },
  );
}
