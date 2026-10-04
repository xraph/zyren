import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren_game/flutter_zyren_game.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/play.dart';
import 'play_session_test.dart' show compile, TestRenderer;
import 'package:zyren_studio/zyren_studio.dart';
import 'play_widgets_test.dart' show PlayInputFixture;

void main() {
  testWidgets('default Play gamepads respect focus, modal gates and detach', (
    tester,
  ) async {
    final authoring = createGameDevelopmentAuthoring();
    final document = GameTemplate(
      GameTemplateKind.exploration,
      authoring,
    ).create(projectId: 'play-gamepad').document;
    final original = document.encode();
    final session = GameSession(project: compile(document, authoring), seed: 7)
      ..step();
    final map = GameInputMap.fromJson(
      session.entities.entities
          .singleWhere((e) => e.handle.id == 'player')
          .components
          .singleWhere((c) => c.type == 'game.input')
          .data,
    );
    final actions = GameActionState(map), source = PlayInputFixture();
    final events = StreamController<GameInputEvent>.broadcast(sync: true);
    final connections = StreamController<GamepadConnection>.broadcast(
      sync: true,
    );
    final failures = <Object>[];
    GamepadAdapter factory(GameInputAdapter input) => GamepadAdapter(
      input: input,
      source: events.stream,
      connections: connections.stream,
      listDevices: () async => [
        const GamepadConnection('gamepad:test', 'Fixture', true),
      ],
    );
    void axis(double value) => events.add(
      GameInputEvent(
        deviceId: 'gamepad:test',
        control: 'axis.leftStickX',
        value: value,
        timestamp: 0,
      ),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GamePlayInput(
              actions: actions,
              session: session,
              source: source,
              enabled: true,
              gamepadFactory: factory,
              onGamepadError: failures.add,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();
      axis(1);
      expect(actions.axis('move.x'), 1);
      final modal = InputRouter.forSource(source).block();
      expect(actions.axis('move.x'), 0);
      axis(1);
      expect(actions.axis('move.x'), 0);
      modal.dispose();
      axis(1);
      expect(actions.axis('move.x'), 1);
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      axis(1);
      expect(actions.axis('move.x'), 0);
      await tester.tap(find.byType(GamePlayInput));
      await tester.pump();
      axis(1);
      expect(actions.axis('move.x'), 1);
      connections.add(
        const GamepadConnection('gamepad:test', 'Fixture', false),
      );
      expect(actions.axis('move.x'), 0);
      events.addError(StateError('Controller disconnected unexpectedly'));
      await tester.pump();
      expect(failures, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(events.hasListener, isFalse);
      expect(connections.hasListener, isFalse);
      expect(actions.axis('move.x'), 0);
      expect(document.encode(), original);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.close);
      await events.close();
      await connections.close();
      await source.eventsController.close();
    }
  });

  testWidgets(
    'Play app suspension releases held keys and preserves manual pause',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final authoring = createGameDevelopmentAuthoring();
      final document = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'play-lifecycle').document;
      final session = GameSession(
        project: compile(document, authoring),
        seed: 7,
      )..step();
      final actor = session.entities.entities.singleWhere(
        (e) => e.handle.id == 'player',
      );
      final actions = GameActionState(
        GameInputMap.fromJson(
          actor.components.singleWhere((c) => c.type == 'game.input').data,
        ),
      );
      final source = PlayInputFixture();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GamePlayInput(
                actions: actions,
                session: session,
                source: source,
                enabled: true,
                enableGamepads: false,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.byType(GamePlayInput));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
        expect(actions.axis('move.z'), 1);
        final epoch = session.epoch;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(session.paused, isTrue);
        expect(session.epoch, greaterThan(epoch));
        expect(actions.axis('move.z'), 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(session.paused, isFalse);
        expect(actions.axis('move.z'), 0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
        session.pause();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(session.paused, isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(session.isClosed, isFalse);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(session.close);
        await source.eventsController.close();
      }
    },
  );
  testWidgets(
    'native Play controls reflect background pause and foreground resume',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final authoring = createGameDevelopmentAuthoring();
      final document = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'play-view-lifecycle').document;
      final scene = StudioScene(document), original = document.encode();
      final source = PlayInputFixture();
      final play = GamePlaySession(
        authoredScene: scene,
        fixtureRendererFactory: () async => TestRenderer(),
      );
      try {
        await tester.runAsync(() => play.start(compile(document, authoring)));
        play.simulation!.step();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  GamePlayControls(session: play),
                  Expanded(
                    child: GamePlayInput(
                      actions: play.actions,
                      session: play.simulation!.session,
                      source: source,
                      enabled: true,
                      enableGamepads: false,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.byType(GamePlayInput));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
        expect(play.actions!.axis('move.z'), 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(play.state, GamePlayState.paused);
        expect(play.actions!.axis('move.z'), 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(play.state, GamePlayState.running);
        expect(play.actions!.axis('move.z'), 0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
        final body = play.resolveBody(play.inputActor!)!,
            before = body.state.pose.position;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
        for (var i = 0; i < 6; i++) {
          play.simulation!.step();
        }
        expect(
          body.state.pose.position.z,
          greaterThan(before.z + .05),
          reason: 'Foreground resume must reacquire native possession.',
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
        expect(scene.capture().encode(), original);
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(play.stop);
        play.dispose();
        await source.eventsController.close();
      }
    },
  );
}
