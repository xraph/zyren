import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';

CompiledGameProject recipe({int hz = 60}) => CompiledGameProject(
  project: GameProject(
    id: 'test',
    startupLevel: 'level',
    levels: [
      GameLevel(
        id: 'level',
        scene: GameSceneIdentity('scene', 'pin'),
        entities: [GameEntityRecord(id: 'actor')],
      ),
    ],
    registry: GameRegistry(),
  ),
  fixedHz: hz,
);

class Probe extends GameSystem {
  @override
  final String id;
  @override
  final GamePhase phase;
  @override
  final Set<String> dependencies;
  final List<String> calls;
  final void Function(GameSession)? update;
  final void Function(GameSession)? onStart, onPause, onResume;
  final bool failStart;
  Probe(
    this.id,
    this.phase,
    this.calls, {
    this.dependencies = const {},
    this.update,
    this.onStart,
    this.onPause,
    this.onResume,
    this.failStart = false,
  });
  @override
  void start(GameSession session) {
    calls.add('start:$id');
    if (failStart) throw StateError('attach');
    onStart?.call(session);
  }

  @override
  void fixedUpdate(GameSession session) {
    calls.add('$id:${session.tick}');
    update?.call(session);
  }

  @override
  void pause(GameSession session) {
    calls.add('pause:$id');
    onPause?.call(session);
  }

  @override
  void resume(GameSession session) {
    calls.add('resume:$id');
    onResume?.call(session);
  }

  @override
  Future<void> dispose(GameSession session) async {
    calls.add('close:$id');
  }
}

void main() {
  test(
    'startup pause defers remaining systems without advancing a tick',
    () async {
      final calls = <String>[];
      final session = GameSession(
        project: recipe(),
        seed: 1,
        systems: [
          Probe('first', GamePhase.commands, calls, onStart: (s) => s.pause()),
          Probe('second', GamePhase.physics, calls),
        ],
      );
      expect(session.advance(1 / 60), 0);
      expect(session.tick, 0);
      expect(calls, ['start:first', 'pause:first']);
      final actor = session.entities.entities.single.handle;
      session.resume();
      session.step();
      expect(session.entities.entities.single.handle, actor);
      expect(session.tick, 1);
      expect(calls, [
        'start:first',
        'pause:first',
        'resume:first',
        'start:second',
        'first:1',
        'second:1',
      ]);
      await session.close();
      expect(calls.sublist(calls.length - 2), ['close:second', 'close:first']);
    },
  );
  test(
    'startup close prevents later attachment and tick advancement',
    () async {
      final calls = <String>[];
      final session = GameSession(
        project: recipe(),
        seed: 1,
        systems: [
          Probe(
            'first',
            GamePhase.commands,
            calls,
            onStart: (s) {
              s.close();
            },
          ),
          Probe('second', GamePhase.physics, calls),
        ],
      );
      session.step();
      expect(session.tick, 0);
      expect(calls, ['start:first']);
      await session.close();
      expect(calls, ['start:first', 'close:first']);
      expect(session.entities.length, 0);
    },
  );
  for (final transition in ['pause', 'resume']) {
    test(
      '$transition hook failures stop ticks, discard work and remain closable',
      () async {
        final calls = <String>[];
        final failure = StateError('$transition failure');
        final session = GameSession(
          project: recipe(),
          seed: 1,
          systems: [
            Probe(
              'first',
              GamePhase.commands,
              calls,
              onResume: transition == 'resume' ? (_) => throw failure : null,
            ),
            Probe(
              'second',
              GamePhase.physics,
              calls,
              onPause: transition == 'pause' ? (_) => throw failure : null,
            ),
          ],
        );
        session.step();
        if (transition == 'resume') session.pause();
        final actor = session.entities.entities.single.handle;
        session.commands.enqueue(
          GameCommand(actor, 2, 'jump'),
          session.entities,
        );
        session.enqueueMutation((s) => calls.add('mutation'));
        var notifications = 0;
        session.listenState(() => notifications++);
        expect(
          transition == 'pause' ? session.pause : session.resume,
          throwsA(same(failure)),
        );
        expect(session.fault, same(failure));
        expect(session.paused, isTrue);
        expect(session.commands.length, 0);
        expect(notifications, 1);
        expect(() => session.step(), throwsStateError);
        expect(() => session.advance(1), throwsStateError);
        expect(() => session.resume(), throwsStateError);
        expect(calls, isNot(contains('mutation')));
        await session.close();
        expect(calls.sublist(calls.length - 2), [
          'close:second',
          'close:first',
        ]);
      },
    );
  }
  test(
    'ordered phases and dependencies execute once per integer tick',
    () async {
      final calls = <String>[];
      final session = GameSession(
        project: recipe(),
        seed: 7,
        systems: [
          Probe('physics', GamePhase.physics, calls),
          Probe('input', GamePhase.commands, calls),
          Probe(
            'controller',
            GamePhase.controllers,
            calls,
            dependencies: {'input'},
          ),
          Probe('rules', GamePhase.rules, calls, dependencies: {'physics'}),
        ],
      );
      session.step();
      session.step();
      expect(session.tick, 2);
      expect(calls.where((e) => !e.startsWith('start')), [
        'input:1',
        'controller:1',
        'physics:1',
        'rules:1',
        'input:2',
        'controller:2',
        'physics:2',
        'rules:2',
      ]);
      expect(session.entities.length, 1);
      await session.close();
      expect(calls.sublist(calls.length - 4), [
        'close:rules',
        'close:physics',
        'close:controller',
        'close:input',
      ]);
      await session.close();
      expect(() => session.step(), throwsStateError);
    },
  );
  test(
    'realtime catch up reports discarded time and retains every tick event',
    () async {
      final session = GameSession(
        project: recipe(),
        seed: 1,
        maxCatchUpSteps: 4,
        systems: [
          Probe(
            'emitter',
            GamePhase.rules,
            [],
            update: (s) => s.events.emit(s.tick, 'tick'),
          ),
        ],
      );
      expect(session.advance(1), 4);
      expect(session.droppedSeconds, closeTo(56 / 60, 1e-9));
      expect(session.events.drain().map((e) => e.tick), [1, 2, 3, 4]);
      session.advance(1 / 120);
      expect(session.tick, 4);
      session.advance(1 / 120);
      expect(session.tick, 5);
      await session.close();
    },
  );
  test(
    'pause clears commands, increments epoch and resumes with no accumulated time',
    () async {
      final session = GameSession(project: recipe(), seed: 1);
      session.step();
      final actor = session.entities.entities.single.handle;
      expect(
        session.commands.enqueue(
          GameCommand(actor, 2, 'jump'),
          session.entities,
        ),
        isTrue,
      );
      session.advance(1 / 120);
      final epoch = session.epoch;
      session.pause();
      session.step();
      session.advance(10);
      expect(session.tick, 1);
      expect(session.commands.length, 0);
      expect(session.epoch, epoch + 1);
      session.resume();
      session.advance(1 / 120);
      expect(session.tick, 1);
      session.advance(1 / 120);
      expect(session.tick, 2);
      await session.close();
    },
  );
  test(
    'listener and system removal during callbacks skips removed work',
    () async {
      final calls = <String>[];
      final session = GameSession(
        project: recipe(),
        seed: 1,
        systems: [
          Probe(
            'first',
            GamePhase.rules,
            calls,
            update: (s) => s.removeSystem('second'),
          ),
          Probe('second', GamePhase.rules, calls),
        ],
      );
      late GameEventSubscription second;
      session.events.listen((_) => second.cancel());
      second = session.events.listen((_) => calls.add('event:second'));
      session.events.emit(0, 'hello');
      session.step();
      expect(calls, isNot(contains('second:1')));
      expect(calls, isNot(contains('event:second')));
      await session.close();
      expect(calls.where((s) => s == 'close:second'), hasLength(1));
    },
  );
  test(
    'partial startup and update failures invalidate work and remain closable',
    () async {
      final calls = <String>[];
      final session = GameSession(
        project: recipe(),
        seed: 1,
        systems: [
          Probe('first', GamePhase.commands, calls),
          Probe('bad', GamePhase.physics, calls, failStart: true),
          Probe('last', GamePhase.rules, calls),
        ],
      );
      expect(() => session.step(), throwsStateError);
      expect(session.fault, isNotNull);
      expect(() => session.step(), throwsStateError);
      await session.close();
      expect(calls, ['start:first', 'start:bad', 'close:bad', 'close:first']);
      final reentrant = GameSession(
        project: recipe(),
        seed: 1,
        systems: [Probe('bad', GamePhase.rules, [], update: (s) => s.step())],
      );
      expect(() => reentrant.step(), throwsStateError);
      await reentrant.close();
    },
  );
  test(
    'invalid recipes, duplicate systems, missing deps and phase inversion fail',
    () {
      expect(() => recipe(hz: 0), throwsRangeError);
      expect(
        () => GameSession(project: recipe(hz: 30), seed: 1, fixedHz: 60),
        throwsArgumentError,
      );
      for (final systems in [
        [Probe('x', GamePhase.rules, []), Probe('x', GamePhase.rules, [])],
        [
          Probe('x', GamePhase.rules, [], dependencies: {'missing'}),
        ],
        [
          Probe('x', GamePhase.commands, [], dependencies: {'y'}),
          Probe('y', GamePhase.rules, []),
        ],
        [
          Probe('x', GamePhase.rules, [], dependencies: {'y'}),
          Probe('y', GamePhase.rules, [], dependencies: {'x'}),
        ],
      ]) {
        expect(
          () => GameSession(project: recipe(), seed: 1, systems: systems),
          throwsStateError,
        );
      }
    },
  );
  test(
    'queued structural changes stop at pause and callbacks queue the next tick',
    () async {
      final session = GameSession(project: recipe(), seed: 1);
      final calls = <int>[];
      session.enqueueMutation((s) {
        calls.add(s.tick);
        s.enqueueMutation((next) => calls.add(next.tick));
      });
      session.step();
      expect(calls, [1]);
      session.step();
      expect(calls, [1, 2]);
      session.enqueueMutation((s) => s.pause());
      session.enqueueMutation((s) => calls.add(99));
      session.step();
      expect(session.paused, isTrue);
      expect(calls, [1, 2]);
      session.resume();
      session.step();
      expect(calls, [1, 2]);
      await session.close();
    },
  );
  test(
    'bounded event delivery defers recursive emissions and rejects overflow',
    () {
      final bus = GameEventBus(capacity: 2);
      final order = <String>[];
      bus.listen((event) {
        order.add('a:${event.payload}');
        if (event.payload == 'one') bus.emit(1, 'two');
      });
      bus.listen((event) => order.add('b:${event.payload}'));
      bus.emit(1, 'one');
      expect(order, ['a:one', 'b:one', 'a:two', 'b:two']);
      expect(() => bus.emit(1, 'three'), throwsStateError);
      expect(bus.drain(), hasLength(2));
      bus.close();
      expect(() => bus.emit(2, 'closed'), throwsStateError);
    },
  );
}
