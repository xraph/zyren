/// Optional integration with Zyren's shared timeline and frame demand.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'zyren_scientific.dart';

/// Animates one loaded two-frame window. The stable target belongs to your
/// scene. The shared timeline owns playback, pause, seek and frame demand.
final class ScientificSliceTrack extends TimelineTrack {
  @override
  final Object3D target;
  final TemporalScalarWindow window;
  final ScalarTransferFunction transfer;
  final SliceAxis axis;
  final double index, coordinateTolerance, secondsPerTimeUnit;
  final ScientificTimeInterpolation interpolation;
  Mesh? _mesh;
  bool _disposed = false;
  TemporalScalarSample? _sample;
  ScientificSliceTrack({
    required this.target,
    required this.window,
    required this.transfer,
    required this.axis,
    required this.index,
    required this.coordinateTolerance,
    this.secondsPerTimeUnit = 1,
    this.interpolation = ScientificTimeInterpolation.linear,
  }) {
    if (!secondsPerTimeUnit.isFinite || secondsPerTimeUnit <= 0) {
      throw ArgumentError('Explicit time conversion must be positive.');
    }
    final micros =
        (window.last.key.time - window.first.key.time) *
        secondsPerTimeUnit *
        1e6;
    if (!micros.isFinite ||
        micros > 9007199254740991 ||
        (window.last.key.time > window.first.key.time && micros < .5)) {
      throw ArgumentError(
        'Timeline duration exceeds or collapses at microsecond precision.',
      );
    }
    prepare(Duration.zero);
  }
  @override
  Duration get end => Duration(
    microseconds:
        ((window.last.key.time - window.first.key.time) *
                secondsPerTimeUnit *
                1e6)
            .round(),
  );
  TemporalScalarSample? get sample => _sample;
  @override
  void Function() prepare(Duration time) {
    if (_disposed) throw StateError('Scientific timeline track has closed.');
    final t =
        (window.first.key.time + time.inMicroseconds / 1e6 / secondsPerTimeUnit)
            .clamp(window.first.key.time, window.last.key.time);
    final next = window.sample(t, interpolation: interpolation);
    final mesh = ScalarSlice.build(
      grid: next.grid,
      transfer: transfer,
      axis: axis,
      index: index,
      coordinateTolerance: coordinateTolerance,
    ).createMesh();
    if (_mesh != null && _mesh!.parent != target) {
      throw StateError('Scientific timeline geometry was changed externally.');
    }
    return () {
      if (_disposed) throw StateError('Scientific timeline track has closed.');
      target.batch(() {
        _mesh?.parent?.remove(_mesh!);
        if (mesh != null) target.add(mesh);
      });
      _mesh = mesh;
      _sample = next;
    };
  }

  void dispose() {
    _disposed = true;
    _mesh?.parent?.remove(_mesh!);
    _mesh = null;
    _sample = null;
  }
}
