import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren_game/flutter_zyren_game.dart';
import 'package:zyren_game/zyren_game.dart';

class InputFixture implements InputSource {
  final source = StreamController<ScenePointerEvent>.broadcast(sync: true);
  @override
  Stream<ScenePointerEvent> get events => source.stream;
  @override
  Registration registerGesture(SceneGesture gesture) => Registration(() {});
}

GameActionState actions() => GameActionState(
  GameInputMap(
    actions: [
      GameActionDefinition('move'),
      GameActionDefinition('jump', button: true),
    ],
    bindings: [
      GameInputBinding('key.w', 'move'),
      GameInputBinding('key.space', 'jump'),
      GameInputBinding('axis.leftStickX', 'move'),
    ],
  ),
);
GameSession session() => GameSession(
  project: CompiledGameProject(
    project: GameProject(
      id: 'game',
      startupLevel: 'level',
      levels: [
        GameLevel(
          id: 'level',
          scene: GameSceneIdentity('scene', 'pin'),
          entities: [],
        ),
      ],
      registry: GameRegistry(),
    ),
  ),
  seed: 1,
);
void main() {
  testWidgets(
    'touch pad cancellation releases both axes and HUD tracks ticks',
    (tester) async {
      final state = GameActionState(
        GameInputMap(
          actions: [GameActionDefinition('x'), GameActionDefinition('y')],
          bindings: [],
        ),
      );
      final game = session();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                GameHud(
                  actions: state,
                  session: game,
                  builder: (_, snapshot) => Text('Tick ${snapshot.tick}'),
                ),
                GameAxisPad(
                  actions: state,
                  xAction: 'x',
                  yAction: 'y',
                  label: 'Move',
                ),
              ],
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(GameAxisPad));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(40, -20));
      await tester.pump();
      expect(state.axis('x'), greaterThan(0));
      expect(state.axis('y'), greaterThan(0));
      await gesture.cancel();
      await tester.pump();
      expect(state.axis('x'), 0);
      expect(state.axis('y'), 0);
      game.step();
      await tester.pump();
      expect(find.text('Tick 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(game.close);
    },
  );

  test('shared router honors editor capture and cancellation', () async {
    final source = InputFixture();
    final state = actions();
    final events = <ScenePointerPhase>[];
    final adapter = GameInputAdapter(
      actions: state,
      source: source,
      onPointer: (event) => events.add(event.phase),
    );
    adapter.setFocus(true);
    final router = InputRouter.forSource(source);
    final editor = router.register(
      id: 'editor',
      priority: InputPriority.tools,
      claims: (_) => true,
      onEvent: (_) {},
    );
    source.source.add(
      ScenePointerEvent(
        point: const ViewportPoint(1, 1),
        phase: ScenePointerPhase.down,
      ),
    );
    expect(events, isEmpty);
    editor.dispose();
    source.source.add(
      ScenePointerEvent(
        point: const ViewportPoint(1, 1),
        phase: ScenePointerPhase.down,
      ),
    );
    expect(events, [ScenePointerPhase.down]);
    state.setAxis(deviceId: 'keyboard', action: 'move', value: 1);
    final blocked = router.block();
    final nested = router.block();
    expect(state.axis('move'), 0);
    expect(state.enabled, isFalse);
    nested.dispose();
    expect(state.enabled, isFalse);
    expect(events.last, ScenePointerPhase.cancel);
    expect(adapter.active, isFalse);
    blocked.dispose();
    expect(state.enabled, isTrue);
    adapter.dispose();
    await source.source.close();
  });
  test(
    'gamepad connection loss releases held input and ignores stale discovery',
    () async {
      final source = InputFixture();
      final state = actions();
      final input = GameInputAdapter(actions: state, source: source)
        ..setFocus(true);
      final events = StreamController<GameInputEvent>.broadcast(sync: true);
      final connections = StreamController<GamepadConnection>.broadcast(
        sync: true,
      );
      final listed = Completer<List<GamepadConnection>>();
      final adapter = GamepadAdapter(
        input: input,
        source: events.stream,
        connections: connections.stream,
        listDevices: () => listed.future,
      );
      final start = adapter.start();
      connections.add(const GamepadConnection('pad', 'Controller', true));
      events.add(
        GameInputEvent(
          deviceId: 'pad',
          control: 'axis.leftStickX',
          value: 1,
          timestamp: 1,
        ),
      );
      expect(state.axis('move'), 1);
      connections.add(const GamepadConnection('pad', 'Controller', false));
      expect(state.axis('move'), 0);
      listed.complete([const GamepadConnection('pad', 'Controller', true)]);
      await start;
      expect(adapter.devices, isEmpty);
      events.add(
        GameInputEvent(
          deviceId: 'pad',
          control: 'axis.leftStickX',
          value: 1,
          timestamp: 2,
        ),
      );
      expect(state.axis('move'), 0);
      await adapter.dispose();
      input.dispose();
      await source.source.close();
      await events.close();
      await connections.close();
    },
  );
  testWidgets('a visible play view leaves WASD to focused text entry', (
    tester,
  ) async {
    final state = actions();
    final game = session();
    final controller = SceneController();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GameSceneBinding(
            controller: controller,
            session: game,
            actions: state,
            autofocus: true,
            viewportBuilder: (_) => const ColoredBox(color: Colors.black),
            hud: const Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 240,
                child: TextField(key: ValueKey('chat')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    expect(state.axis('move'), 1);
    await tester.tap(find.byKey(const ValueKey('chat')));
    await tester.pump();
    expect(state.axis('move'), 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    expect(state.axis('move'), 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await tester.enterText(find.byKey(const ValueKey('chat')), 'wasd');
    expect(find.text('wasd'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(game.close);
    controller.dispose();
    await tester.pump();
    await controller.whenDisposed;
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'touch cancellation and accessible keyboard activation release cleanly',
    (tester) async {
      final state = actions();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GameActionButton(
              actions: state,
              action: 'jump',
              label: 'Jump',
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Jump')),
      );
      expect(state.pressed('jump'), isTrue);
      await gesture.cancel();
      expect(state.pressed('jump'), isFalse);
      state.takePressed('jump');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(state.takePressed('jump'), isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(state.pressed('jump'), isFalse);
    },
  );
}
