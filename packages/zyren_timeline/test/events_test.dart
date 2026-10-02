import 'dart:async';

import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_timeline/zyren_timeline.dart';

import '../../zyren/test/support/fakes.dart';

const end = Duration(milliseconds: 100);
Duration ms(int value) => Duration(milliseconds: value);

void main() {
  late Scene scene;
  late Mesh mesh;
  late SceneTimelinePlugin timeline;
  late SceneEngine engine;
  late List<TimelineEvent> events;
  var demands = 0;

  setUp(() {
    scene = Scene();
    mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    events = [];
    demands = 0;
  });

  Future<void> attach() async {
    engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [timeline],
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
    addTearDown(engine.dispose);
  }

  Future<void> create({
    bool loop = false,
    Duration duration = end,
    List<TimelineMarker>? markers,
    int maxEventsPerAdvance = 1024,
    List<TimelineTrack>? tracks,
  }) async {
    timeline = SceneTimelinePlugin(
      duration: duration,
      loop: loop,
      maxEventsPerAdvance: maxEventsPerAdvance,
      markers:
          markers ??
          [
            TimelineMarker(Duration.zero, id: 'start'),
            TimelineMarker(ms(25), id: 'quarter'),
            TimelineMarker(ms(50), id: 'half'),
            TimelineMarker(ms(50), id: 'half-again'),
            TimelineMarker(end, id: 'end'),
          ],
      tracks:
          tracks ??
          [
            TransformTrack(mesh, [
              TransformKeyframe(Duration.zero),
              TransformKeyframe(duration, position: const Vec3(10, 0, 0)),
            ]),
          ],
    );
    final subscription = timeline.events.listen(events.add);
    addTearDown(subscription.cancel);
    await attach();
  }

  Future<void> tick(Duration delta) async {
    await engine.render(
      elapsed: delta,
      time: FrameTime(elapsed: delta, delta: delta),
      width: 8,
      height: 8,
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> play() async {
    timeline.play();
    await tick(Duration.zero);
  }

  List<(String, int)> keys() => [
    for (final event in events) (event.marker.id, event.loopIndex),
  ];

  test(
    'crossings keep time order, ties and immutable sampled positions',
    () async {
      await create();
      await play();
      await tick(ms(50));
      expect(keys(), [
        ('start', 0),
        ('quarter', 0),
        ('half', 0),
        ('half-again', 0),
      ]);
      expect(events.first.position, Duration.zero);
      expect(
        events.skip(1).map((event) => event.position),
        everyElement(ms(50)),
      );
      expect(mesh.position, const Vec3(5, 0, 0));
      await tick(Duration.zero);
      expect(events, hasLength(4));
      await tick(ms(80));
      expect(keys().last, ('end', 0));
      expect(events.last.position, end);
      expect(timeline.isPlaying, isFalse);
      expect(demands, 0);
      await tick(ms(80));
      expect(events, hasLength(5));
    },
  );

  test('pause and repeated play do not repeat the start marker', () async {
    await create();
    await play();
    timeline.play();
    timeline.pause();
    await play();
    expect(keys(), [('start', 0)]);
    expect(demands, 1);
    await tick(ms(25));
    timeline.pause();
    await tick(end);
    await play();
    expect(keys(), [('start', 0), ('quarter', 0)]);
  });

  test('seeking is silent and a zero seek arms the start for replay', () async {
    await create();
    timeline.seek(ms(75));
    await play();
    expect(events, isEmpty);
    timeline.seek(ms(25));
    expect(timeline.isPlaying, isTrue);
    await tick(ms(25));
    expect(keys(), [('half', 0), ('half-again', 0)]);
    timeline.pause();
    timeline.seek(Duration.zero);
    expect(events, hasLength(2));
    await play();
    expect(keys().last, ('start', 0));
  });

  test('playing a finished clip restarts markers and loop index', () async {
    await create();
    await play();
    await tick(end);
    await play();
    expect(keys(), [
      ('start', 0),
      ('quarter', 0),
      ('half', 0),
      ('half-again', 0),
      ('end', 0),
      ('start', 0),
    ]);
    expect(timeline.position, Duration.zero);
    expect(demands, 1);
  });

  test(
    'loop endpoints fire before the next start even on exact landing',
    () async {
      await create(loop: true);
      timeline.seek(ms(75));
      await play();
      await tick(ms(25));
      expect(keys(), [('end', 0), ('start', 1)]);
      expect(timeline.position, Duration.zero);
      expect(
        events.map((event) => event.position),
        everyElement(Duration.zero),
      );
      timeline.pause();
      await play();
      expect(events, hasLength(2));
      await tick(ms(25));
      expect(keys().last, ('quarter', 1));
      timeline.seek(ms(25));
      await tick(ms(25));
      expect(keys().last, ('half-again', 0));
    },
  );

  test(
    'one advance delivers all crossed loops in chronological order',
    () async {
      await create(loop: true);
      timeline.seek(ms(75));
      await play();
      await tick(ms(250));
      expect(keys(), [
        ('end', 0),
        ('start', 1),
        ('quarter', 1),
        ('half', 1),
        ('half-again', 1),
        ('end', 1),
        ('start', 2),
        ('quarter', 2),
        ('half', 2),
        ('half-again', 2),
        ('end', 2),
        ('start', 3),
        ('quarter', 3),
      ]);
      expect(timeline.position, ms(25));
      expect(events.map((event) => event.position), everyElement(ms(25)));
    },
  );

  test(
    'events-only clips deliver live records without replaying history',
    () async {
      await create(tracks: []);
      final lateEvents = <TimelineEvent>[];
      await play();
      final subscription = timeline.events.listen(lateEvents.add);
      addTearDown(subscription.cancel);
      await tick(end);
      expect(lateEvents.map((event) => event.marker.id), [
        'quarter',
        'half',
        'half-again',
        'end',
      ]);
      expect(timeline.isPlaying, isFalse);
    },
  );

  test('playback needs no event listener', () async {
    timeline = SceneTimelinePlugin(
      duration: end,
      tracks: [],
      markers: [TimelineMarker(end, id: 'end')],
    );
    await attach();
    await play();
    await tick(end);
    expect(timeline.position, end);
    expect(timeline.isPlaying, isFalse);
    expect(demands, 0);
  });

  test(
    'a zero seek while playing emits the rearmed start on the next advance',
    () async {
      await create();
      await play();
      await tick(ms(25));
      timeline.seek(Duration.zero);
      expect(events, hasLength(2));
      await tick(ms(25));
      expect(keys(), [
        ('start', 0),
        ('quarter', 0),
        ('start', 0),
        ('quarter', 0),
      ]);
    },
  );

  test(
    'a negative explicit delta pauses without markers or pose edits',
    () async {
      await create();
      await play();
      await expectLater(
        engine.render(
          elapsed: Duration.zero,
          time: FrameTime(delta: ms(-25)),
          width: 8,
          height: 8,
        ),
        throwsArgumentError,
      );
      expect(keys(), [('start', 0)]);
      expect(mesh.position, Vec3.zero);
      expect(timeline.position, Duration.zero);
      expect(demands, 0);
    },
  );

  test(
    'crossings match an independent absolute-time walk across varied steps',
    () async {
      await create(loop: true);
      await play();
      var absolute = 0;
      final expected = <(String, int)>[('start', 0)];
      for (final step in [25, 0, 101, 50, 324, 200, 1, 74, 225]) {
        final next = absolute + step;
        final crossings = <(int, String, int)>[];
        for (var cycle = absolute ~/ 100; cycle <= next ~/ 100; cycle++) {
          for (final marker in timeline.markers) {
            final time = cycle * 100 + marker.time.inMilliseconds;
            if (time > absolute && time <= next) {
              crossings.add((time, marker.id, cycle));
            }
          }
        }
        // Dart's sort is not stable, so use declaration order to break ties.
        final order = {
          for (var i = 0; i < timeline.markers.length; i++)
            timeline.markers[i].id: i,
        };
        crossings.sort((a, b) {
          final time = a.$1.compareTo(b.$1);
          if (time != 0) return time;
          final cycle = a.$3.compareTo(b.$3);
          return cycle != 0 ? cycle : order[a.$2]!.compareTo(order[b.$2]!);
        });
        expected.addAll(
          crossings.map((crossing) => (crossing.$2, crossing.$3)),
        );
        await tick(ms(step));
        expect(keys(), expected);
        expect(timeline.position, ms(next % 100));
        absolute = next;
      }
    },
  );

  test('async listeners can seek without interrupting pose sampling', () async {
    await create();
    final poses = <Vec3>[];
    final subscription = timeline.events.listen((event) {
      if (event.marker.id == 'quarter') {
        poses.add(mesh.position);
        timeline.seek(Duration.zero);
      }
    });
    addTearDown(subscription.cancel);
    timeline.play();
    expect(events, isEmpty);
    await tick(Duration.zero);
    await tick(ms(50));
    expect(poses, [const Vec3(5, 0, 0)]);
    expect(timeline.position, Duration.zero);
    expect(events.last.position, ms(50));
    expect(events.last.marker.id, 'half-again');
  });

  test('invalid target pauses without events or a new position', () async {
    await create();
    await play();
    scene.remove(mesh);
    await expectLater(tick(end), throwsStateError);
    expect(keys(), [('start', 0)]);
    expect(timeline.position, Duration.zero);
    expect(mesh.position, Vec3.zero);
    expect(demands, 0);
    expect(timeline.isPlaying, isFalse);
  });

  test(
    'failed sample does not deliver crossed markers or earlier edits',
    () async {
      final invalid = _InvalidTrack(scene.add(Group()));
      await create(
        tracks: [
          TransformTrack(mesh, [
            TransformKeyframe(Duration.zero),
            TransformKeyframe(end, position: Vec3.one),
          ]),
          invalid,
        ],
      );
      await play();
      invalid.fail = true;
      await expectLater(tick(end), throwsStateError);
      expect(keys(), [('start', 0)]);
      expect(mesh.position, Vec3.zero);
      expect(timeline.position, Duration.zero);
      expect(demands, 0);
    },
  );

  test(
    'detached reuse preserves consumed starts and releases demand',
    () async {
      await create();
      await play();
      await engine.dispose();
      expect(demands, 0);
      expect(() => timeline.play(), throwsStateError);
      expect(() => timeline.seek(end), throwsStateError);
      await attach();
      await play();
      expect(keys(), [('start', 0)]);
      await tick(ms(25));
      expect(keys().last, ('quarter', 0));
    },
  );

  test(
    'event limit rejects an entire advance before allocating or editing',
    () async {
      await create(
        loop: true,
        duration: const Duration(microseconds: 1),
        markers: [TimelineMarker(Duration.zero, id: 'tick')],
        maxEventsPerAdvance: 2,
      );
      await play();
      await expectLater(tick(const Duration(days: 1)), throwsStateError);
      expect(keys(), [('tick', 0)]);
      expect(timeline.position, Duration.zero);
      expect(mesh.position, Vec3.zero);
      expect(demands, 0);
      await play();
      await tick(const Duration(microseconds: 2));
      expect(keys(), [('tick', 0), ('tick', 1), ('tick', 2)]);
    },
  );

  test(
    'limit includes zero-time starts and rejects them before sampling',
    () async {
      await create(
        maxEventsPerAdvance: 1,
        markers: [
          TimelineMarker(Duration.zero, id: 'one'),
          TimelineMarker(Duration.zero, id: 'two'),
        ],
      );
      mesh.position = Vec3.one;
      expect(() => timeline.play(), throwsStateError);
      expect(mesh.position, Vec3.one);
      expect(events, isEmpty);
      expect(demands, 0);
    },
  );

  test(
    'an empty marker list handles many loops without enumerating them',
    () async {
      await create(
        duration: const Duration(microseconds: 1),
        markers: [],
        loop: true,
      );
      await play();
      await tick(const Duration(days: 1));
      expect(events, isEmpty);
      expect(timeline.position, Duration.zero);
      expect(timeline.isPlaying, isTrue);
    },
  );

  test('markers and their timeline list validate and freeze input', () {
    expect(() => TimelineMarker(ms(-1), id: 'bad'), throwsArgumentError);
    expect(() => TimelineMarker(Duration.zero, id: '  '), throwsArgumentError);
    final marker = TimelineMarker(ms(50), id: 'half', label: 'Halfway');
    final markers = [marker];
    final clip = SceneTimelinePlugin(
      duration: end,
      tracks: [],
      markers: markers,
    );
    markers.clear();
    expect(clip.markers.single, same(marker));
    expect(clip.markers.single.label, 'Halfway');
    expect(() => clip.markers.clear(), throwsUnsupportedError);
    for (final invalid in [
      [TimelineMarker(ms(101), id: 'past')],
      [marker, marker],
      [marker, TimelineMarker(ms(25), id: 'before')],
    ]) {
      expect(
        () => SceneTimelinePlugin(duration: end, tracks: [], markers: invalid),
        throwsArgumentError,
      );
    }
    expect(
      () => SceneTimelinePlugin(
        duration: end,
        tracks: [],
        maxEventsPerAdvance: 0,
      ),
      throwsArgumentError,
    );
  });
}

class _InvalidTrack extends TimelineTrack {
  @override
  final Object3D target;
  bool fail = false;
  _InvalidTrack(this.target);
  @override
  Duration get end => const Duration(milliseconds: 100);
  @override
  void Function() prepare(Duration time) {
    if (fail) throw StateError('Invalid sampled pose');
    return () {};
  }
}
