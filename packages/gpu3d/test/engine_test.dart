import 'dart:async';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

void main() {
  const serviceKey = ServiceKey<List<String>>('shared-history');
  test(
    'orders plugins, shares typed services and detaches consumers first',
    () async {
      final events = <String>[];
      final renderer = TestRenderer(events);
      final history = <String>[];
      late PluginContext retained;
      final provider = TestPlugin(
        'provider',
        events,
        onAttach: (context) {
          retained = context;
          context.provide(serviceKey, history);
        },
      );
      final consumer = TestPlugin(
        'consumer',
        events,
        dependencies: {'provider'},
        onAttach: (context) => context.service(serviceKey).add('attached'),
        onBefore: (context, _) => context.service(serviceKey).add('frame'),
        onDetach: (context) => context.service(serviceKey).add('detached'),
      );
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        plugins: [consumer, provider],
      );
      expect(engine.pluginIds, ['provider', 'consumer']);
      await engine.render(elapsed: Duration.zero, width: 3, height: 2);
      await engine.dispose();
      await engine.dispose();
      expect(events, [
        'provider.attach',
        'consumer.attach',
        'provider.before',
        'consumer.before',
        'test.render',
        'provider.after',
        'consumer.after',
        'consumer.detach',
        'provider.detach',
        'test.dispose',
      ]);
      expect(history, ['attached', 'frame', 'detached']);
      expect(() => retained.service(serviceKey), throwsStateError);
      expect(renderer.disposals, 1);
    },
  );

  test('rejects invalid graphs before creating a GPU', () async {
    var creates = 0;
    final events = <String>[];
    final graphs = [
      [TestPlugin('a', events), TestPlugin('a', events)],
      [
        TestPlugin('a', events, dependencies: {'missing'}),
      ],
      [
        TestPlugin('a', events, dependencies: {'b'}),
        TestPlugin('b', events, dependencies: {'a'}),
      ],
      [TestPlugin('', events)],
    ];
    final expected = [
      throwsArgumentError,
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.pluginDependencyMissing,
        ),
      ),
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.pluginDependencyCycle,
        ),
      ),
      throwsArgumentError,
    ];
    for (var i = 0; i < graphs.length; i++) {
      final plugins = graphs[i];
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async {
            creates++;
            return TestRenderer(events);
          },
          plugins: plugins,
        ),
        expected[i],
      );
    }
    expect(creates, 0);
  });

  test('unsupported capability fails before attaching any plugin', () async {
    final events = <String>[];
    final renderer = TestRenderer(events);
    await expectLater(
      SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        plugins: [
          TestPlugin('plain', events),
          TestPlugin(
            'compute',
            events,
            requiredFeatures: {RenderFeature.compute},
          ),
        ],
      ),
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.unsupportedFeature,
        ),
      ),
    );
    expect(events, ['test.dispose']);
  });

  test(
    'failed attach rolls back partial resources and continues after cleanup failure',
    () async {
      final events = <String>[];
      final renderer = TestRenderer(events);
      late PluginContext providerContext;
      final provider = TestPlugin(
        'provider',
        events,
        onAttach: (context) {
          providerContext = context;
          context.provide(serviceKey, <String>[]);
        },
      );
      final failure = TestPlugin(
        'failure',
        events,
        dependencies: {'provider'},
        onAttach: (context) {
          context.service(serviceKey).add('allocated');
          throw StateError('attach failed');
        },
        onDetach: (context) {
          context.service(serviceKey).clear();
          throw StateError('detach failed');
        },
      );
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => renderer,
          plugins: [failure, provider],
        ),
        throwsA(
          isA<EngineInitializationException>()
              .having(
                (e) => e.cause.toString(),
                'cause',
                contains('attach failed'),
              )
              .having(
                (e) => e.cleanupError,
                'cleanup',
                isA<EngineCleanupException>(),
              ),
        ),
      );
      expect(events, [
        'provider.attach',
        'failure.attach',
        'failure.detach',
        'provider.detach',
        'test.dispose',
      ]);
      expect(() => providerContext.service(serviceKey), throwsStateError);
      final next = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer(events),
        plugins: [provider],
      );
      await next.dispose();
    },
  );

  test('does not overwrite services and rejects late registration', () async {
    final events = <String>[];
    late PluginContext retained;
    final first = TestPlugin(
      'first',
      events,
      onAttach: (context) {
        retained = context;
        context.provide(serviceKey, <String>[]);
      },
    );
    final second = TestPlugin(
      'second',
      events,
      dependencies: {'first'},
      onAttach: (context) => context.provide(serviceKey, <String>[]),
    );
    await expectLater(
      SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer(events),
        plugins: [first, second],
      ),
      throwsStateError,
    );
    expect(() => retained.provide(serviceKey, <String>[]), throwsStateError);
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer(events),
      plugins: [first],
    );
    expect(
      () => retained.provide(const ServiceKey<int>('late'), 1),
      throwsStateError,
    );
    await engine.dispose();
  });

  test(
    'exclusive ownership survives factory failure and releases after disposal',
    () async {
      final events = <String>[];
      final plugin = TestPlugin('owned', events);
      final gate = Completer<SceneRenderer>();
      final pending = SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () => gate.future,
        plugins: [plugin],
      );
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => TestRenderer(events),
          plugins: [plugin],
        ),
        throwsStateError,
      );
      final failure = expectLater(pending, throwsStateError);
      gate.completeError(StateError('device unavailable'));
      await failure;
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer(events),
        plugins: [plugin],
      );
      await engine.dispose();
    },
  );

  test(
    'waits for in-flight frames before detaching and rejects extra work',
    () async {
      final events = <String>[];
      final gate = Completer<void>();
      final renderer = TestRenderer(events, gate: gate);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        plugins: [TestPlugin('plugin', events)],
      );
      final frame = engine.render(elapsed: Duration.zero, width: 4, height: 4);
      await expectLater(
        engine.render(elapsed: Duration.zero, width: 4, height: 4),
        throwsStateError,
      );
      final disposing = engine.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(events, isNot(contains('plugin.detach')));
      await expectLater(
        engine.render(elapsed: Duration.zero, width: 4, height: 4),
        throwsStateError,
      );
      gate.complete();
      await frame;
      await disposing;
      expect(events, [
        'plugin.attach',
        'plugin.before',
        'test.render',
        'plugin.after',
        'plugin.detach',
        'test.dispose',
      ]);
    },
  );

  test(
    'frame failure releases the flight and teardown still releases the renderer',
    () async {
      final events = <String>[];
      var fail = true;
      final plugin = TestPlugin(
        'hook',
        events,
        onBefore: (_, _) {
          if (fail) throw StateError('hook failed');
        },
        onDetach: (_) => throw StateError('detach failed'),
      );
      final renderer = TestRenderer(events);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
        plugins: [plugin],
      );
      await expectLater(
        engine.render(elapsed: Duration.zero, width: 4, height: 4),
        throwsStateError,
      );
      expect(renderer.renders, 0);
      fail = false;
      await engine.render(
        elapsed: const Duration(seconds: 1),
        width: 4,
        height: 4,
      );
      await expectLater(
        engine.dispose(),
        throwsA(isA<EngineCleanupException>()),
      );
      expect(renderer.disposals, 1);
    },
  );

  test('bounds frame sizes and deltas including resumed clocks', () async {
    final events = <String>[];
    final plugin = TestPlugin('timing', events);
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer(events),
      plugins: [plugin],
    );
    await expectLater(
      engine.render(elapsed: Duration.zero, width: 65, height: 4),
      throwsArgumentError,
    );
    for (final ms in [0, 20, 2000, 10]) {
      await engine.render(
        elapsed: Duration(milliseconds: ms),
        width: 4,
        height: 4,
      );
    }
    expect(plugin.frames.map((f) => f.delta.inMilliseconds), [0, 20, 100, 0]);
    await engine.dispose();
  });
}
