import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/play.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'play_session_test.dart' show compile, TestRenderer, DelayedRenderer;

class PlayInputFixture implements InputSource {
  final eventsController = StreamController<ScenePointerEvent>.broadcast(
    sync: true,
  );
  @override
  Stream<ScenePointerEvent> get events => eventsController.stream;
  @override
  Registration registerGesture(SceneGesture _) => Registration(() {});
}

StudioEditorHostController makePlayHost(StudioScene scene) =>
    StudioEditorHostController(
      services: StudioEditorServices(
        scene: scene,
        commands: StudioCommands(
          scene: scene,
          sessionId: 'play-test',
          isAllowed: (_) => true,
          isAvailable: () => true,
        ),
        agents: AgentRegistry(grantedScopes: const {}),
        isAvailable: () => true,
        viewportSnapshot: () => const {},
        capabilities: () => const {},
        applyDocument: scene.apply,
      ),
    );

void main() {
  test(
    'host coalesces native teardown and rejects a new launch until cleanup finishes',
    () async {
      final a = createGameDevelopmentAuthoring();
      final d = GameTemplate(
        GameTemplateKind.exploration,
        a,
      ).create(projectId: 'pending-host').document;
      final host = makePlayHost(StudioScene(d));
      final renderer = DelayedRenderer();
      host.register(
        GamePlayContribution(
          authoring: a,
          compile: (doc, _) async => compile(doc, a),
          fixtureRendererFactory: () async => renderer,
        ).contribution,
      );
      await host.startPlay('game.play');
      final stopping = host.stopPlay();
      await renderer.entered.future;
      expect(host.stopPlay(), same(stopping));
      await expectLater(host.startPlay('game.play'), throwsStateError);
      renderer.release.complete();
      await stopping;
      expect(host.activePlaySession, isNull);
      await host.startPlay('game.play');
      expect(host.activePlaySession, isA<GamePlaySession>());
      await host.close();
    },
  );
  testWidgets(
    'compact runtime controls and selection work in both themes and widths',
    (tester) async {
      for (final width in [1200.0, 328.0]) {
        for (final brightness in Brightness.values) {
          tester.view.physicalSize = Size(width, 700);
          tester.view.devicePixelRatio = 1;
          final a = createGameDevelopmentAuthoring(),
              d = GameTemplate(
                GameTemplateKind.exploration,
                createGameDevelopmentAuthoring(),
              ).create(projectId: 'widgets').document;
          final play = GamePlaySession(
            authoredScene: StudioScene(d),
            fixtureRendererFactory: () async => TestRenderer(),
          );
          await tester.runAsync(() => play.start(compile(d, a)));
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Scaffold(
                body: Column(
                  children: [
                    GamePlayControls(session: play),
                    Expanded(child: GameRuntimeInspector(session: play)),
                  ],
                ),
              ),
            ),
          );
          await tester.tap(find.text('Pause'));
          await tester.pump();
          expect(play.isPaused, isTrue);
          final tick = play.tick;
          await tester.tap(find.text('Step'));
          await tester.pump();
          expect(play.tick, tick + 1);
          play.runtimeSelection = play.inputActor;
          await tester.pump();
          expect(find.textContaining('primitive'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(play.stop);
          play.dispose();
        }
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
  testWidgets(
    'host Stop and apply-back release the seat for immediate relaunch',
    (tester) async {
      final a = createGameDevelopmentAuthoring();
      final d = GameTemplate(
        GameTemplateKind.exploration,
        a,
      ).create(projectId: 'host').document;
      final scene = StudioScene(d), host = makePlayHost(StudioScene(d));
      host.register(
        GamePlayContribution(
          authoring: a,
          compile: (doc, _) async => compile(doc, a),
          fixtureRendererFactory: () async => TestRenderer(),
        ).contribution,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioEditorHost(
              controller: host,
              viewport: const SizedBox(),
              workspaceBuilder: (_, panes, _) =>
                  panes.singleWhere((p) => p.id == 'game.runtime').child,
            ),
          ),
        ),
      );
      await tester.runAsync(() => host.startPlay('game.play'));
      await tester.pump();
      final first = host.activePlaySession as GamePlaySession;
      await tester.runAsync(() => tester.tap(find.text('Stop')));
      await tester.runAsync(host.stopPlay);
      await tester.pump();
      expect(host.activePlaySession, isNull);
      expect(first.state, GamePlayState.stopped);
      await tester.runAsync(() => host.startPlay('game.play'));
      await tester.pump();
      final second = host.activePlaySession as GamePlaySession;
      expect(second, isNot(same(first)));
      second.actions!.setAxis(deviceId: 'fixture', action: 'move.z', value: 1);
      for (var i = 0; i < 5; i++) {
        second.simulation!.step();
      }
      await tester.tap(find.text('Pause'));
      await tester.pump();
      await tester.runAsync(
        () => tester.tap(find.text('Apply selected fields')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Apply runtime fields'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.text('Apply selected')));
      await tester.pump();
      await tester.runAsync(host.stopPlay);
      await tester.pumpAndSettle();
      expect(host.activePlaySession, isNull);
      expect(host.services.scene.canUndo, isTrue);
      expect(scene.canUndo, isFalse);
      await tester.runAsync(() => host.startPlay('game.play'));
      expect(host.activePlaySession, isA<GamePlaySession>());
      await tester.runAsync(host.stopPlay);
      host.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => host.whenSettled);
    },
  );
  testWidgets('compile failure provides working retry and import actions', (
    tester,
  ) async {
    final a = createGameDevelopmentAuthoring();
    final d = GameTemplate(
      GameTemplateKind.exploration,
      a,
    ).create(projectId: 'retry').document;
    final host = makePlayHost(StudioScene(d));
    var failing = true, imports = 0;
    host.register(
      GamePlayContribution(
        authoring: a,
        compile: (doc, _) async {
          if (failing) throw StateError('Missing pinned asset');
          return compile(doc, a);
        },
        fixtureRendererFactory: () async => TestRenderer(),
        importAssets: (_) async {
          imports++;
          failing = false;
        },
      ).contribution,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudioEditorHost(
            controller: host,
            viewport: const SizedBox(),
            workspaceBuilder: (_, panes, _) =>
                panes.singleWhere((p) => p.id == 'game.runtime').child,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      Object? failure;
      try {
        await host.startPlay('game.play');
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<StateError>());
    });
    await tester.pump();
    expect(find.text('Game play failed'), findsOneWidget);
    await tester.tap(find.text('Import assets'));
    await tester.pump();
    expect(imports, 1);
    await tester.runAsync(() => tester.tap(find.text('Retry')));
    await tester.runAsync(() async {
      for (var i = 0; i < 10 && host.activePlaySession == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
    expect(host.activePlaySession, isA<GamePlaySession>());
    expect(tester.takeException(), isNull);
    await tester.runAsync(host.stopPlay);
    host.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => host.whenSettled);
  });
  testWidgets(
    'late action initialization respects inspector focus and modal blocking',
    (tester) async {
      final source = PlayInputFixture(), inspector = FocusNode();
      final state = GameActionState(
        GameInputMap(
          actions: [GameActionDefinition('move')],
          bindings: [GameInputBinding('key.w', 'move')],
        ),
      );
      GameActionState? actions;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, update) {
                rebuild = update;
                return Column(
                  children: [
                    TextField(focusNode: inspector),
                    GamePlayInput(
                      actions: actions,
                      source: source,
                      enabled: true,
                      child: const SizedBox(
                        key: ValueKey('play-viewport'),
                        width: 100,
                        height: 100,
                        child: ColoredBox(color: Colors.black),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      inspector.requestFocus();
      await tester.pump();
      rebuild(() => actions = state);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      expect(state.axis('move'), 0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.tap(find.byKey(const ValueKey('play-viewport')));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      expect(state.axis('move'), 1);
      final gate = InputRouter.forSource(source).block();
      expect(state.axis('move'), 0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      expect(state.axis('move'), 0);
      gate.dispose();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      expect(state.axis('move'), 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.pumpWidget(const SizedBox());
      inspector.dispose();
      await source.eventsController.close();
    },
  );
}
