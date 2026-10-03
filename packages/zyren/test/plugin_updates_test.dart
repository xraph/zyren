import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'support/fakes.dart';

class _BindingBackend implements GraphBackend {
  int closes = 0;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'bindings',
    features: {
      RenderFeature.scopedResources,
      RenderFeature.shaderCompilation,
      RenderFeature.renderGraphs,
      RenderFeature.frameGraphs,
      RenderFeature.environmentLighting,
      RenderFeature.temporalAntialiasing,
    },
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 4096),
  );
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<SceneEngine> create(
    List<ScenePlugin> plugins,
    TestRenderer renderer,
  ) => SceneEngine.create(
    scene: Scene(),
    camera: PerspectiveCamera(),
    rendererFactory: () async => renderer,
    plugins: plugins,
  );

  test('reorders stable plugins and validates before detachment', () async {
    final events = <String>[];
    final renderer = TestRenderer(events);
    final a = TestPlugin('a', events), b = TestPlugin('b', events);
    final engine = await create([a, b], renderer);
    events.clear();
    await engine.updatePlugins([b, a]);
    expect(engine.pluginIds, ['b', 'a']);
    expect(events, isEmpty);
    await expectLater(
      engine.updatePlugins([
        TestPlugin('bad', events, dependencies: {'missing'}),
      ]),
      throwsA(isA<SceneException>()),
    );
    await expectLater(
      engine.updatePlugins([
        TestPlugin('gpu', events, requiredFeatures: {RenderFeature.compute}),
      ]),
      throwsA(isA<SceneException>()),
    );
    expect(engine.pluginIds, ['b', 'a']);
    expect(events, isEmpty);
    await engine.render(elapsed: Duration.zero, width: 2, height: 2);
    expect(events.take(2), ['b.before', 'a.before']);
    await engine.dispose();
    expect(renderer.disposals, 1);
  });

  test(
    'provider replacement rebinds transitive consumers and retains independent context',
    () async {
      const key = ServiceKey<List<int>>('value');
      final events = <String>[];
      PluginContext? originalIndependent, currentIndependent;
      final first = TestPlugin(
        'provider',
        events,
        onAttach: (c) => c.provide(key, [1]),
      );
      final second = TestPlugin(
        'provider',
        events,
        onAttach: (c) => c.provide(key, [2]),
      );
      List<int>? observed;
      final consumer = TestPlugin(
        'consumer',
        events,
        dependencies: {'provider'},
        onAttach: (c) => observed = c.service(key),
      );
      final transitive = TestPlugin(
        'transitive',
        events,
        dependencies: {'consumer'},
      );
      final independent = TestPlugin(
        'independent',
        events,
        onAttach: (c) => currentIndependent = c,
      );
      final engine = await create([
        transitive,
        consumer,
        first,
        independent,
      ], TestRenderer(events));
      originalIndependent = currentIndependent;
      events.clear();
      await engine.updatePlugins([transitive, consumer, second, independent]);
      expect(events, [
        'transitive.detach',
        'consumer.detach',
        'provider.detach',
        'provider.attach',
        'consumer.attach',
        'transitive.attach',
      ]);
      expect(observed, [2]);
      expect(currentIndependent, same(originalIndependent));
      await engine.dispose();
    },
  );

  test(
    'waits for active frame, defers new frames and then uses new list',
    () async {
      final events = <String>[];
      final gate = Completer<void>();
      final renderer = TestRenderer(events, gate: gate);
      final old = TestPlugin('old', events), next = TestPlugin('next', events);
      final engine = await create([old], renderer);
      final frame = engine.render(elapsed: Duration.zero, width: 2, height: 2);
      await Future<void>.delayed(Duration.zero);
      final update = engine.updatePlugins([next]);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['old.attach', 'old.before', 'test.render']);
      await expectLater(
        engine.render(elapsed: Duration.zero, width: 2, height: 2),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.frameDeferred,
          ),
        ),
      );
      gate.complete();
      await frame;
      await update;
      expect(events, [
        'old.attach',
        'old.before',
        'test.render',
        'old.after',
        'old.detach',
        'next.attach',
      ]);
      await engine.render(
        elapsed: const Duration(seconds: 1),
        width: 2,
        height: 2,
      );
      expect(renderer.renders, 2);
      await engine.dispose();
    },
  );

  test(
    'failed attachment cleans candidate services and scopes then permits retry',
    () async {
      const key = ServiceKey<Object>('candidate');
      final events = <String>[];
      final renderer = TestRenderer(events);
      var closed = 0;
      var fail = true;
      final stable = TestPlugin('stable', events);
      final candidate = TestPlugin(
        'candidate',
        events,
        onAttach: (c) {
          c.provide(key, Object());
          c.scope.keep(Registration(() => closed++));
          if (fail) throw StateError('attach failed');
        },
      );
      final engine = await create([stable], renderer);
      await expectLater(
        engine.updatePlugins([stable, candidate]),
        throwsA(
          isA<PluginUpdateException>().having(
            (e) => e.activePluginIds,
            'remaining',
            ['stable'],
          ),
        ),
      );
      expect(closed, 1);
      expect(renderer.disposals, 0);
      fail = false;
      await engine.updatePlugins([stable, candidate]);
      expect(engine.pluginIds, ['stable', 'candidate']);
      await engine.dispose();
      expect(closed, 2);
    },
  );

  test(
    'dispose drains a pending attachment and keeps ownership exclusive',
    () async {
      final events = <String>[];
      final renderer = TestRenderer(events);
      final gate = Completer<void>(), entered = Completer<void>();
      var closed = 0;
      final candidate = TestPlugin(
        'candidate',
        events,
        onAttach: (c) async {
          c.scope.keep(Registration(() => closed++));
          entered.complete();
          await gate.future;
        },
      );
      final engine = await create([], renderer);
      final update = engine.updatePlugins([candidate]);
      final failed = expectLater(update, throwsA(isA<PluginUpdateException>()));
      await entered.future;
      await expectLater(
        create([candidate], TestRenderer([])),
        throwsStateError,
      );
      final disposed = engine.dispose();
      expect(closed, 1);
      expect(renderer.disposals, 0);
      gate.complete();
      await failed;
      await disposed;
      expect(renderer.disposals, 1);
      expect(closed, 1);
    },
  );

  test(
    'updates from awaited frame hooks reject instead of deadlocking',
    () async {
      final events = <String>[];
      late SceneEngine engine;
      final plugin = TestPlugin(
        'hook',
        events,
        onBefore: (_, _) async =>
            expectLater(engine.updatePlugins([]), throwsStateError),
      );
      engine = await create([plugin], TestRenderer(events));
      await engine.render(elapsed: Duration.zero, width: 2, height: 2);
      expect(engine.pluginIds, ['hook']);
      await engine.dispose();
    },
  );
  test(
    'closed environment, temporal and composition bindings can be reclaimed',
    () async {
      final backend = _BindingBackend();
      final events = <String>[];
      EnvironmentBinding? environment;
      TemporalBinding? temporal;
      FrameGraphBinding? frameGraph;
      final manual = TestPlugin(
        'manual',
        events,
        onAttach: (c) {
          environment = c.environment;
          temporal = c.temporal;
          frameGraph = c.frameGraph;
        },
      );
      final shared = TestPlugin(
        'shared',
        events,
        onAttach: (c) {
          c.graph;
        },
      );
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [manual],
      );
      final oldEnvironment = environment!,
          oldTemporal = temporal!,
          oldGraph = frameGraph!;
      await engine.updatePlugins([shared]);
      expect(() => oldEnvironment.environment = null, throwsStateError);
      expect(oldTemporal.reset, throwsStateError);
      expect(() => oldGraph.graph = null, throwsStateError);
      await engine.updatePlugins([manual]);
      expect(environment, isNot(same(oldEnvironment)));
      expect(temporal, isNot(same(oldTemporal)));
      expect(frameGraph, isNot(same(oldGraph)));
      engine.invalidateHistory();
      expect(backend.closes, 0);
      await engine.dispose();
      expect(backend.closes, 1);
    },
  );

  test(
    'failed provider replacement leaves no consumer using its old service',
    () async {
      const key = ServiceKey<Object>('owned');
      final events = <String>[];
      final provider = TestPlugin(
        'provider',
        events,
        onAttach: (c) => c.provide(key, Object()),
      );
      late PluginContext oldConsumer;
      final consumer = TestPlugin(
        'consumer',
        events,
        dependencies: {'provider'},
        onAttach: (c) {
          oldConsumer = c;
          c.service(key);
        },
      );
      final stable = TestPlugin('stable', events);
      final engine = await create([
        provider,
        consumer,
        stable,
      ], TestRenderer(events));
      final broken = TestPlugin(
        'provider',
        events,
        onAttach: (_) => throw StateError('failed'),
      );
      await expectLater(
        engine.updatePlugins([broken, consumer, stable]),
        throwsA(isA<PluginUpdateException>()),
      );
      expect(engine.pluginIds, ['stable']);
      expect(() => oldConsumer.service(key), throwsStateError);
      await engine.updatePlugins([provider, consumer, stable]);
      expect(engine.pluginIds, ['provider', 'consumer', 'stable']);
      await engine.dispose();
    },
  );

  test('live contexts retain invalidate and demand callbacks', () async {
    final events = <String>[];
    var invalidations = 0, demands = 0;
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer(events),
      onInvalidate: () => invalidations++,
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
    await engine.updatePlugins([
      TestPlugin(
        'live',
        events,
        onAttach: (c) {
          c.invalidate();
          c.acquireFrameDemand();
        },
      ),
    ]);
    expect(invalidations, greaterThan(0));
    expect(demands, 1);
    await engine.updatePlugins([]);
    expect(demands, 0);
    await engine.dispose();
  });
}
