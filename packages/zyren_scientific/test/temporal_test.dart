import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
import 'package:zyren_scientific/timeline.dart';
import 'scientific_test.dart' show grid, transfer, source;

final seconds = ScientificUnit(quantity: 'time', symbol: 's');
ScientificFrameKey key(int i) =>
    ScientificFrameKey(id: 'frame:$i', version: 'v1', time: i.toDouble());
ScalarGrid3D frame(int i) =>
    grid(x: 2, y: 2, z: 2, values: List.filled(8, i.toDouble()));
void main() {
  test(
    'versioned temporal interpolation and exact-frame missing semantics',
    () {
      final window = TemporalScalarWindow(
        first: ScientificFrame(key(0), frame(0)),
        last: ScientificFrame(
          key(2),
          grid(x: 2, y: 2, z: 2, values: [null, 2, 2, 2, 2, 2, 2, 2]),
        ),
        timeUnit: seconds,
      );
      expect(window.sample(0).grid.missingCount, 0);
      expect(window.sample(1).grid.valueAt(1, 0, 0), 1);
      expect(window.sample(1).grid.missingCount, 1);
      expect(window.sample(1).frames.map((f) => f.version), ['v1', 'v1']);
      expect(
        window
            .sample(1, interpolation: ScientificTimeInterpolation.discrete)
            .grid
            .valueAt(1, 0, 0),
        0,
      );
      expect(() => window.sample(3), throwsRangeError);
    },
  );
  test(
    'source retains only two frames, cancels stale loads and reports failures',
    () async {
      final started = Completer<void>(), finish = Completer<void>();
      var loads = 0;
      final s = TemporalScalarSource(
        source: source,
        timeUnit: seconds,
        frames: [for (var i = 0; i < 5; i++) key(i)],
        load: (k, token) async {
          loads++;
          if (k.time == 0 && !started.isCompleted) {
            started.complete();
            await finish.future;
          }
          if (k.time == 4) throw StateError('Source frame missing');
          return frame(k.time.toInt());
        },
      );
      final stale = s.seek(.5);
      final rejected = expectLater(stale, throwsA(isA<ScientificCancelled>()));
      await started.future;
      final latest = s.seek(2.5);
      finish.complete();
      await rejected;
      final result = await latest;
      expect(result.grid.valueAt(0, 0, 0), 2.5);
      expect(s.residentFrames, 2);
      expect(loads, 3);
      expect((await s.seek(2.25)).grid.valueAt(0, 0, 0), 2.25);
      expect(loads, 3);
      await expectLater(s.seek(4), throwsStateError);
      expect(s.residentFrames, 0);
      await s.dispose();
      expect(s.residentBytes, 0);
      expect(() => s.seek(1), throwsStateError);
    },
  );
  test(
    'payload budgets, invalid frame order and source mismatch fail explicitly',
    () async {
      expect(
        () => TemporalScalarSource(
          source: source,
          timeUnit: seconds,
          frames: [key(1), key(0)],
          load: (k, c) async => frame(0),
        ),
        throwsArgumentError,
      );
      final s = TemporalScalarSource(
        source: source,
        timeUnit: seconds,
        frames: [key(0), key(1)],
        maxResidentBytes: 80,
        load: (k, c) async => frame(k.time.toInt()),
      );
      await expectLater(s.seek(.5), throwsStateError);
      expect(s.residentBytes, 72);
      await s.dispose();
      final changed = TemporalScalarSource(
        source: source,
        timeUnit: seconds,
        frames: [key(0), key(1)],
        load: (k, c) async => k.time == 0 ? frame(0) : grid(x: 3),
      );
      await expectLater(changed.seek(.5), throwsArgumentError);
      await changed.dispose();
    },
  );
  test('timeline preparation is atomic and stable parent survives seeks', () {
    final parent = Group();
    final track = ScientificSliceTrack(
      target: parent,
      window: TemporalScalarWindow(
        first: ScientificFrame(key(0), frame(0)),
        last: ScientificFrame(key(2), frame(2)),
        timeUnit: seconds,
      ),
      transfer: transfer(min: 0, max: 2),
      axis: SliceAxis.z,
      index: 0,
      coordinateTolerance: 0,
    );
    expect(
      () => ScientificSliceTrack(
        target: Group(),
        window: track.window,
        transfer: track.transfer,
        axis: track.axis,
        index: track.index,
        coordinateTolerance: 0,
        secondsPerTimeUnit: 1e-9,
      ),
      throwsArgumentError,
    );
    final edit = track.prepare(const Duration(seconds: 1));
    expect(parent.children, isEmpty);
    edit();
    expect(parent.children.length, 1);
    expect(track.sample!.grid.valueAt(0, 0, 0), 1);
    track.apply(const Duration(seconds: 2));
    expect(parent.children.length, 1);
    expect(track.sample!.grid.valueAt(0, 0, 0), 2);
    track.dispose();
    expect(parent.children, isEmpty);
    expect(() => track.prepare(Duration.zero), throwsStateError);
  });
}
