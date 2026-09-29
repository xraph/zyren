import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fakes.dart';
import 'package:zyren/rendering.dart';

void main() {
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Widget host(Widget view) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: SizedBox(width: 200, height: 100, child: view)),
  );

  testWidgets(
    'uses injected backend, plugins and presentation and retires every frame',
    (tester) async {
      final events = <String>[];
      final renderer = TestRenderer(events);
      final presenter = TestPresenter('custom presentation', events);
      final plugin = TestPlugin('plugin', events);
      final scene = Scene(), camera = PerspectiveCamera();
      Future<RenderBackend> createRenderer() async => renderer;
      FramePresenter createPresenter() => presenter;
      Widget view() => host(
        sceneView(
          scene: scene,
          camera: camera,
          plugins: [plugin],
          rendererFactory: createRenderer,
          presenterFactory: createPresenter,
        ),
      );
      await tester.pumpWidget(view());
      await frames(tester);
      expect(find.text('custom presentation'), findsOneWidget);
      expect(renderer.sizes, everyElement((64, 32)));
      // New list containers with the same plugins do not recreate the device.
      await tester.pumpWidget(view());
      await frames(tester);
      expect(events.where((e) => e == 'plugin.attach'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(renderer.disposals, 1);
      expect(presenter.disposals, 1);
      expect(presenter.frames, isNotEmpty);
      expect(presenter.frames.map((f) => f.disposals), everyElement(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'replacement waits for old presentation and suppresses stale frames',
    (tester) async {
      final events = <String>[];
      final first = TestRenderer(events, name: 'first');
      final second = TestRenderer(events, name: 'second');
      final gate = Completer<void>();
      final oldPresenter = TestPresenter('old', events, gate: gate);
      final newPresenter = TestPresenter('new', events);
      final plugin = TestPlugin('shared instance', events);
      final scene = Scene(), camera = PerspectiveCamera();
      await tester.pumpWidget(
        host(
          sceneView(
            scene: scene,
            camera: camera,
            plugins: [plugin],
            rendererFactory: () async => first,
            presenterFactory: () => oldPresenter,
          ),
        ),
      );
      await frames(tester);
      expect(events, contains('old.present'));
      await tester.pumpWidget(
        host(
          sceneView(
            scene: scene,
            camera: camera,
            plugins: [plugin],
            rendererFactory: () async {
              events.add('second.create');
              return second;
            },
            presenterFactory: () => newPresenter,
          ),
        ),
      );
      await frames(tester);
      expect(events, isNot(contains('second.create')));
      gate.complete();
      await frames(tester);
      expect(find.text('old'), findsNothing);
      expect(find.text('new'), findsOneWidget);
      expect(oldPresenter.frames.single.disposals, 1);
      expect(
        events.indexOf('first.dispose'),
        lessThan(events.indexOf('second.create')),
      );
      expect(oldPresenter.disposals, 1);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(second.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removal during initialization cleans up a late device and plugins',
    (tester) async {
      final events = <String>[];
      final gate = Completer<RenderBackend>();
      final renderer = TestRenderer(events);
      final presenter = TestPresenter('late', events);
      await tester.pumpWidget(
        host(
          sceneView(
            scene: Scene(),
            camera: PerspectiveCamera(),
            plugins: [TestPlugin('late-plugin', events)],
            rendererFactory: () => gate.future,
            presenterFactory: () => presenter,
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      gate.complete(renderer);
      await frames(tester);
      expect(renderer.disposals, 1);
      expect(presenter.disposals, 0);
      expect(events, ['test.dispose']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retry releases the failed session before reattaching the same plugins',
    (tester) async {
      final events = <String>[];
      final scene = Scene(), camera = PerspectiveCamera();
      var shouldFail = true;
      final plugin = TestPlugin(
        'retry',
        events,
        onBefore: (_, _) {
          if (shouldFail) throw StateError('temporary failure');
        },
      );
      final renderers = <TestRenderer>[];
      Future<RenderBackend> createRenderer() async {
        final renderer = TestRenderer(events);
        renderers.add(renderer);
        return renderer;
      }

      FramePresenter createPresenter() => TestPresenter('recovered', events);
      Widget view(int revision) => host(
        sceneView(
          scene: scene,
          camera: camera,
          rendererFactory: createRenderer,
          presenterFactory: createPresenter,
          plugins: [plugin],
          restartToken: revision,
          errorBuilder: (_, _) => const Text('Retry needed'),
        ),
      );
      await tester.pumpWidget(view(0));
      await frames(tester);
      expect(find.text('Retry needed'), findsOneWidget);
      shouldFail = false;
      await tester.pumpWidget(view(1));
      await frames(tester);
      expect(find.text('recovered'), findsOneWidget);
      expect(renderers.length, 2);
      expect(renderers.first.disposals, 1);
      expect(events.where((e) => e == 'retry.attach'), hasLength(2));
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('presenter construction failure releases the engine', (
    tester,
  ) async {
    final events = <String>[];
    final renderer = TestRenderer(events);
    await tester.pumpWidget(
      host(
        sceneView(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => renderer,
          presenterFactory: () => throw StateError('bad presenter'),
          plugins: [TestPlugin('plugin', events)],
          errorBuilder: (_, error) => Text(error.toString()),
        ),
      ),
    );
    await frames(tester);
    expect(find.textContaining('bad presenter'), findsOneWidget);
    expect(renderer.disposals, 1);
    expect(events, ['plugin.attach', 'plugin.detach', 'test.dispose']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an error observer cannot prevent native cleanup', (
    tester,
  ) async {
    final events = <String>[];
    final renderer = TestRenderer(events);
    final plugin = TestPlugin(
      'failure',
      events,
      onBefore: (_, _) => throw StateError('Frame failed.'),
    );
    await tester.pumpWidget(
      host(
        sceneView(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => renderer,
          plugins: [plugin],
          onError: (_) => throw StateError('Observer failed.'),
          errorBuilder: (_, _) => const Text('Error shown'),
        ),
      ),
    );
    await frames(tester);
    expect(tester.takeException(), isA<StateError>());
    expect(find.text('Error shown'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    expect(renderer.disposals, 1);
    expect(events, contains('failure.detach'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('displayed-frame cleanup failure still releases the backend', (
    tester,
  ) async {
    final events = <String>[];
    final renderer = TestRenderer(events);
    final presenter = TestPresenter('frame', events);
    await tester.pumpWidget(
      host(
        sceneView(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => renderer,
          presenterFactory: () => presenter,
        ),
      ),
    );
    await frames(tester);
    presenter.frames.last.failOnDispose = true;
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    expect(tester.takeException(), isA<StateError>());
    expect(renderer.disposals, 1);
    expect(presenter.disposals, 1);
  });

  testWidgets('renders visible inactive windows and pauses only while hidden', (
    tester,
  ) async {
    final events = <String>[];
    final renderer = TestRenderer(events);
    await tester.pumpWidget(
      host(
        sceneView(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => renderer,
          presenterFactory: () => TestPresenter('frame', events),
        ),
      ),
    );
    await frames(tester);
    final focusedCount = renderer.renders;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await frames(tester);
    expect(renderer.renders, greaterThan(focusedCount));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    final count = renderer.renders;
    await frames(tester);
    expect(renderer.renders, count);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await frames(tester);
    expect(renderer.renders, greaterThan(count));
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });

  testWidgets('initializes and renders when launched without input focus', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final events = <String>[];
    final renderer = TestRenderer(events);
    await tester.pumpWidget(
      host(
        sceneView(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => renderer,
          presenterFactory: () =>
              TestPresenter('first unfocused frame', events),
        ),
      ),
    );
    await frames(tester);
    expect(find.text('first unfocused frame'), findsOneWidget);
    expect(renderer.renders, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets(
    'RGBA presenter validates frame storage and displays native pixels',
    (tester) async {
      final presenter = ImageFramePresenter();
      await expectLater(
        presenter.present(RenderedFrame(Uint8List(3), 1, 1)),
        throwsArgumentError,
      );
      // ui codec futures need real asynchronous execution under widget tests.
      final frame = await tester.runAsync(
        () => presenter.present(
          RenderedFrame(Uint8List.fromList([255, 0, 0, 255]), 1, 1),
        ),
      );
      await tester.pumpWidget(host(Builder(builder: frame!.build)));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 1);
      await tester.pumpWidget(const SizedBox());
      frame.dispose();
      await presenter.dispose();
      await expectLater(
        presenter.present(RenderedFrame(Uint8List(4), 1, 1)),
        throwsStateError,
      );
    },
  );
}

Widget sceneView({
  required Scene scene,
  required Camera camera,
  required Future<RenderBackend> Function() rendererFactory,
  PresenterFactory presenterFactory = ImageFramePresenter.create,
  List<ScenePlugin> plugins = const [],
  Object? restartToken,
  void Function(Object)? onError,
  Widget Function(BuildContext, Object)? errorBuilder,
}) => SceneView.scene(
  scene: scene,
  camera: camera,
  plugins: plugins,
  sceneKey: (scene, camera, rendererFactory, presenterFactory, restartToken),
  options: const EngineOptions(
    renderMode: RenderMode.continuous,
    presentation: PresentationPolicy.readbackOnly,
  ),
  runtime: SceneRuntime(
    backendFactory: rendererFactory,
    presenterFactory: presenterFactory,
  ),
  onError: onError,
  errorBuilder: errorBuilder == null
      ? null
      : (context, issue, retry) => errorBuilder(context, issue),
);
