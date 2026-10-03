import 'scalar_grid.dart';
import 'sampling.dart';
import 'work.dart';

enum ScientificTimeInterpolation { discrete, linear }

final class ScientificFrameKey {
  final String id, version;
  final double time;
  ScientificFrameKey({
    required this.id,
    required this.version,
    required this.time,
  }) {
    if (id.trim().isEmpty ||
        id.length > 1024 ||
        version.trim().isEmpty ||
        version.length > 256 ||
        !time.isFinite) {
      throw ArgumentError('A frame needs a finite time, identity and version.');
    }
  }
}

final class ScientificFrame {
  final ScientificFrameKey key;
  final ScalarGrid3D grid;
  const ScientificFrame(this.key, this.grid);
}

final class TemporalScalarSample {
  final ScalarGrid3D grid;
  final double time, fraction;
  final ScientificUnit timeUnit;
  final List<ScientificFrameKey> frames;
  final ScientificTimeInterpolation interpolation;
  TemporalScalarSample._(
    this.grid,
    this.time,
    this.fraction,
    this.timeUnit,
    List<ScientificFrameKey> frames,
    this.interpolation,
  ) : frames = List.unmodifiable(frames);
}

/// A bounded pair of already loaded frames, suitable for synchronous playback.
final class TemporalScalarWindow {
  final ScientificFrame first, last;
  final ScientificUnit timeUnit;
  TemporalScalarWindow({
    required this.first,
    required this.last,
    required this.timeUnit,
  }) {
    if (timeUnit.quantity != 'time' ||
        first.key.time > last.key.time ||
        (first.key.time == last.key.time &&
            (first.key.id != last.key.id ||
                first.key.version != last.key.version ||
                !identical(first.grid, last.grid))) ||
        !(last.key.time - first.key.time).isFinite ||
        !compatibleGrids(first.grid, last.grid)) {
      throw ArgumentError(
        'Temporal frames need ordered times and matching grids, source and units.',
      );
    }
  }
  TemporalScalarSample sample(
    double time, {
    ScientificTimeInterpolation interpolation =
        ScientificTimeInterpolation.linear,
  }) {
    if (!time.isFinite || time < first.key.time || time > last.key.time) {
      throw RangeError('Time is outside the loaded window.');
    }
    final a = first.grid, b = last.grid;
    if (time == last.key.time) {
      return TemporalScalarSample._(b, time, 0, timeUnit, [
        last.key,
      ], interpolation);
    }
    if (time == first.key.time ||
        interpolation == ScientificTimeInterpolation.discrete) {
      return TemporalScalarSample._(a, time, 0, timeUnit, [
        first.key,
      ], interpolation);
    }
    final t = (time - first.key.time) / (last.key.time - first.key.time);
    final values = <double?>[];
    for (var z = 0; z < a.sizeZ; z++) {
      for (var y = 0; y < a.sizeY; y++) {
        for (var x = 0; x < a.sizeX; x++) {
          final av = a.valueAt(x, y, z), bv = b.valueAt(x, y, z);
          values.add(av == null || bv == null ? null : av * (1 - t) + bv * t);
        }
      }
    }
    final result = ScalarGrid3D(
      sizeX: a.sizeX,
      sizeY: a.sizeY,
      sizeZ: a.sizeZ,
      values: values,
      origin: a.origin,
      spacing: a.spacing,
      valueUnit: a.valueUnit,
      coordinateUnit: a.coordinateUnit,
      source: a.source,
      name: a.name,
    );
    return TemporalScalarSample._(result, time, t, timeUnit, [
      first.key,
      last.key,
    ], interpolation);
  }
}

typedef ScientificFrameLoader =
    Future<ScalarGrid3D> Function(
      ScientificFrameKey key,
      ScientificCancellation cancellation,
    );

/// Holds at most two source frames and runs one loader at a time. Your loader
/// should observe cancellation to release external work promptly. Returned
/// interpolated grids and caller-owned source storage are outside this cache.
final class TemporalScalarSource {
  final ScientificSource source;
  final ScientificUnit timeUnit;
  final List<ScientificFrameKey> frames;
  final ScientificFrameLoader load;
  final int maxResidentBytes;
  final _cache = <int, ScalarGrid3D>{};
  ScientificCancellation? _request;
  Future<void> _queue = Future.value();
  bool _disposed = false;
  Object? _layout;
  TemporalScalarSource({
    required this.source,
    required this.timeUnit,
    required List<ScientificFrameKey> frames,
    required this.load,
    this.maxResidentBytes = 18000000,
  }) : frames = List.unmodifiable(frames) {
    if (timeUnit.quantity != 'time' ||
        frames.isEmpty ||
        frames.length > 100000 ||
        maxResidentBytes < 9 ||
        maxResidentBytes > 18000000) {
      throw ArgumentError('Invalid temporal source limits.');
    }
    final ids = <String>{};
    for (var i = 0; i < frames.length; i++) {
      if (!ids.add(frames[i].id) ||
          (i > 0 &&
              (frames[i].time <= frames[i - 1].time ||
                  !(frames[i].time - frames[i - 1].time).isFinite))) {
        throw ArgumentError(
          'Frame identities and ordered times must be unique.',
        );
      }
    }
  }
  int get residentFrames => _cache.length;
  int get residentBytes => _cache.values.fold(0, (n, g) => n + g.payloadBytes);
  bool get isDisposed => _disposed;
  void _check(ScientificCancellation token, ScientificCancellation? external) {
    token.check();
    external?.check();
    if (_disposed) throw StateError('Temporal source has closed.');
  }

  Future<TemporalScalarSample> seek(
    double time, {
    ScientificTimeInterpolation interpolation =
        ScientificTimeInterpolation.linear,
    ScientificCancellation? cancellation,
  }) {
    if (_disposed) throw StateError('Temporal source has closed.');
    if (!time.isFinite || time < frames.first.time || time > frames.last.time) {
      throw RangeError('Requested time is outside the source.');
    }
    _request?.cancel();
    final token = _request = ScientificCancellation(
      isCancellationRequested: () => cancellation?.isCancelled ?? false,
    );
    final future = _queue.then((_) async {
      _check(token, cancellation);
      var low = 0, high = frames.length - 1;
      while (low < high) {
        final mid = (low + high + 1) ~/ 2;
        if (frames[mid].time <= time) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      final right =
          interpolation == ScientificTimeInterpolation.linear &&
              frames[low].time != time
          ? low + 1
          : low;
      final keep = {low, right};
      _cache.removeWhere((i, _) => !keep.contains(i));
      for (final index in keep) {
        if (_cache.containsKey(index)) continue;
        final grid = await load(frames[index], token);
        _check(token, cancellation);
        final layout = (
          grid.sizeX,
          grid.sizeY,
          grid.sizeZ,
          grid.origin,
          grid.spacing,
          grid.coordinateUnit,
          grid.valueUnit,
        );
        if (grid.source.id != source.id ||
            grid.source.kind != source.kind ||
            (_layout != null && _layout != layout)) {
          throw ArgumentError(
            'Loaded frame changed source, units or grid layout.',
          );
        }
        if (residentBytes + grid.payloadBytes > maxResidentBytes) {
          throw StateError('Temporal source exceeds resident payload budget.');
        }
        _layout = layout;
        _cache[index] = grid;
      }
      _check(token, cancellation);
      final window = TemporalScalarWindow(
        first: ScientificFrame(frames[low], _cache[low]!),
        last: ScientificFrame(frames[right], _cache[right]!),
        timeUnit: timeUnit,
      );
      final result = window.sample(
        time == frames[low].time || right != low ? time : frames[low].time,
        interpolation: interpolation,
      );
      _check(token, cancellation);
      return TemporalScalarSample._(
        result.grid,
        time,
        result.fraction,
        timeUnit,
        result.frames,
        interpolation,
      );
    });
    _queue = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  void cancel() => _request?.cancel();
  Future<void> dispose() async {
    _disposed = true;
    _request?.cancel();
    _cache.clear();
    await _queue;
  }
}
