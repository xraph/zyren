import 'package:zyren/zyren.dart';
import 'scalar_grid.dart';
import 'scalar_slice.dart';
import 'slice_view.dart';
import 'transfer_function.dart';
import 'sampling.dart';
import 'surface.dart';
import 'vectors.dart';
import 'temporal.dart';
import 'volume.dart';
import 'work.dart';

enum ScientificRepresentation { slice, isosurface, vectors, streamline, volume }

/// Revision-checked presentation commands shared by UI and runtime agents.
/// Source loaders and GPU controllers remain owned by their host attachment.
final class ScientificFieldView {
  final String id;
  final Scene scene;
  final VectorGrid3D? vectors;
  final TemporalScalarSource? temporal;
  final ScientificVolumeController? volume;
  final double coordinateTolerance, scalarTolerance;
  ScalarGrid3D _grid;
  ScalarTransferFunction _transfer;
  ScientificRepresentation _mode = ScientificRepresentation.slice;
  Mesh? _mesh;
  ScalarSlice? _slice;
  ScientificSurface? _surface;
  ScientificLines? _lines;
  Streamline? _streamline;
  TemporalScalarSample? _time;
  double _threshold,
      _index = 0,
      _vectorScale = .1,
      _volumeOpacity = .2,
      _volumeStep = .05;
  Vec3 _seed;
  int _revision = 0, _meshRevision = 0;
  bool _disposed = false;
  final _disposal = <void Function()>[];
  Future<void> _queue = Future.value();
  ScientificFieldView({
    required this.id,
    required this.scene,
    required ScalarGrid3D grid,
    required ScalarTransferFunction transfer,
    required this.coordinateTolerance,
    this.scalarTolerance = 1e-5,
    this.vectors,
    this.temporal,
    this.volume,
  }) : _grid = grid,
       _transfer = transfer,
       _threshold = transfer.minimum * .5 + transfer.maximum * .5,
       _seed = Vec3(
         (grid.sizeX - 1) * grid.spacing.x * .25,
         (grid.sizeY - 1) * grid.spacing.y * .5,
         (grid.sizeZ - 1) * grid.spacing.z * .5,
       ) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$').hasMatch(id) ||
        !coordinateTolerance.isFinite ||
        coordinateTolerance < 0 ||
        !scalarTolerance.isFinite ||
        scalarTolerance < 0 ||
        grid.valueUnit != transfer.unit ||
        (vectors != null && vectors!.x.coordinateUnit != grid.coordinateUnit) ||
        (temporal != null && temporal!.source.id != grid.source.id)) {
      throw ArgumentError('Invalid scientific field view configuration.');
    }
  }
  int get revision => _revision;
  bool get isDisposed => _disposed;
  ScalarGrid3D get grid => _grid;
  bool get _vectorMode =>
      _mode == ScientificRepresentation.vectors ||
      _mode == ScientificRepresentation.streamline;
  ScientificSource get activeSource =>
      _vectorMode ? vectors!.x.source : _grid.source;
  ScientificUnit get activeUnit =>
      _vectorMode ? vectors!.x.valueUnit : _grid.valueUnit;
  ScalarTransferFunction get transfer => _transfer;
  ScientificRepresentation get representation => _mode;
  Mesh? get mesh => _mesh;
  TemporalScalarSample? get time => _time;
  void checkCurrent({int? expectedRevision}) {
    if (_disposed) {
      throw const ScientificViewException(
        ScientificViewFailure.unavailable,
        'Scientific field view has closed.',
      );
    }
    if ((expectedRevision != null && expectedRevision != revision) ||
        (_mesh != null &&
            (_mesh!.parent != scene || _mesh!.revision != _meshRevision))) {
      throw const ScientificViewException(
        ScientificViewFailure.stale,
        'Scientific view or scene object changed.',
      );
    }
  }

  Future<void> configure({
    required int expectedRevision,
    ScientificRepresentation? representation,
    double? threshold,
    double? sliceIndex,
    ScalarTransferFunction? transfer,
    double? time,
    Vec3? seed,
    double? vectorScale,
    double? volumeOpacity,
    double? volumeSampleDistance,
    ScientificCancellation? cancellation,
  }) {
    final future = _queue.then((_) async {
      checkCurrent(expectedRevision: expectedRevision);
      final token = ScientificCancellation(
        isCancellationRequested: () =>
            _disposed || (cancellation?.isCancelled ?? false),
      );
      token.check();
      final mode = representation ?? _mode, tf = transfer ?? _transfer;
      final iso = threshold ?? _threshold,
          index = sliceIndex ?? _index,
          scale = vectorScale ?? _vectorScale,
          opacity = volumeOpacity ?? _volumeOpacity,
          step = volumeSampleDistance ?? _volumeStep,
          p = seed ?? _seed;
      if (!iso.isFinite ||
          !index.isFinite ||
          !scale.isFinite ||
          scale <= 0 ||
          !opacity.isFinite ||
          opacity < 0 ||
          opacity > 1 ||
          !step.isFinite ||
          step <= 0 ||
          !p.isFinite) {
        throw ArgumentError('Invalid scientific representation settings.');
      }
      final TemporalScalarSample? nextTime;
      if (time != null) {
        if (temporal == null) {
          throw StateError('This field has no temporal source.');
        }
        nextTime = await temporal!.seek(time, cancellation: token);
      } else {
        nextTime = _time;
      }
      final g = nextTime?.grid ?? _grid;
      if (g.valueUnit != tf.unit) {
        throw ArgumentError('Transfer units do not match the scalar field.');
      }
      Mesh? mesh;
      ScalarSlice? slice;
      ScientificSurface? surface;
      ScientificLines? lines;
      Streamline? streamline;
      ScientificVolumeSettings? volumeSettings;
      switch (mode) {
        case ScientificRepresentation.slice:
          slice = ScalarSlice.build(
            grid: g,
            transfer: tf,
            axis: SliceAxis.z,
            index: index,
            coordinateTolerance: coordinateTolerance,
          );
          mesh = slice.createMesh();
        case ScientificRepresentation.isosurface:
          surface = await extractIsosurface(
            grid: g,
            threshold: iso,
            transfer: tf,
            coordinateTolerance: coordinateTolerance,
            cancellation: token,
          );
          mesh = surface.createMesh();
        case ScientificRepresentation.vectors:
        case ScientificRepresentation.streamline:
          final field = vectors;
          if (field == null) throw StateError('This view has no vector field.');
          final magnitude = ScalarTransferFunction(
            unit: field.x.valueUnit,
            minimum: 0,
            maximum: 2,
            stops: tf.stops,
          );
          if (mode == ScientificRepresentation.vectors) {
            lines = await buildVectorGlyphs(
              field: field,
              transfer: magnitude,
              lengthScale: scale,
              coordinateTolerance: coordinateTolerance,
              stride: 3,
              cancellation: token,
            );
          } else {
            streamline = await integrateStreamline(
              field: field,
              seed: p,
              options: StreamlineOptions(maxLength: 10),
              cancellation: token,
            );
            lines = streamline.geometry(
              transfer: magnitude,
              coordinateTolerance: coordinateTolerance,
            );
          }
          mesh = lines.createMesh();
        case ScientificRepresentation.volume:
          if (volume == null) {
            throw StateError('A native volume controller is required.');
          }
          volumeSettings = ScientificVolumeSettings(
            grid: g,
            transfer: VolumeTransferFunction(
              unit: tf.unit,
              minimum: tf.minimum,
              maximum: tf.maximum,
              stops: [
                for (final stop in tf.stops)
                  VolumeStop(
                    stop.position,
                    stop.color,
                    opacity * stop.position,
                  ),
              ],
            ),
            sampleDistance: step,
            referenceDistance: .1,
            coordinateTolerance: coordinateTolerance,
            scalarTolerance: scalarTolerance,
          );
      }
      token.check();
      checkCurrent(expectedRevision: expectedRevision);
      // All CPU work is prepared before the GPU controller atomically swaps.
      if (volume != null) {
        await volume!.setVolume(volumeSettings, cancellation: token);
      }
      // A committed GPU swap is followed synchronously by the scene/state swap.
      scene.batch(() {
        _mesh?.parent?.remove(_mesh!);
        if (mesh != null) scene.add(mesh);
      });
      _grid = g;
      _transfer = tf;
      _mode = mode;
      _threshold = iso;
      _index = index;
      _vectorScale = scale;
      _volumeOpacity = opacity;
      _volumeStep = step;
      _seed = p;
      _mesh = mesh;
      _meshRevision = mesh?.revision ?? 0;
      _slice = slice;
      _surface = surface;
      _lines = lines;
      _streamline = streamline;
      _time = nextTime;
      _revision++;
    });
    _queue = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Map<String, Object?> sample(Vec3 local) {
    checkCurrent();
    final s = sampleScalar(_grid, local);
    final vector = vectors?.sample(_grid.origin + local - vectors!.x.origin);
    return {
      'sourceId': _grid.source.id,
      'sourceKind': _grid.source.kind.name,
      'position': local.storage,
      'coordinateSpace': 'grid-local',
      'status': s.status.name,
      'value': s.value,
      'unit': unitJson(_grid.valueUnit),
      'coordinateUnit': unitJson(_grid.coordinateUnit),
      'vector': vector?.value?.storage,
      'vectorStatus': vector?.status.name,
      'vectorSourceId': vectors?.x.source.id,
      'vectorUnit': vectors == null ? null : unitJson(vectors!.x.valueUnit),
      'vectorTimeStatus': vectors == null ? 'unavailable' : 'static',
      'time': _time?.time,
      'timeUnit': _time == null ? null : unitJson(_time!.timeUnit),
      'interpolation': 'trilinear-source-sample',
      'pixelVisibility': 'unknown',
    };
  }

  Map<String, Object?> inspectHit(PickResult hit) {
    checkCurrent();
    if (!identical(hit.object, _mesh) || hit.sceneRevision != scene.revision) {
      throw const ScientificViewException(
        ScientificViewFailure.stale,
        'Pick target or scene revision changed.',
      );
    }
    final sample = sampleScalar(_grid, hit.point - _grid.origin);
    return {
      'viewId': id,
      'viewRevision': revision,
      'sceneRevision': scene.revision,
      'runtimeObjectId': hit.object.id,
      'sourceId': activeSource.id,
      'representation': _mode.name,
      'triangleIndex': hit.triangleIndex,
      'sourceCell':
          _surface != null &&
              hit.triangleIndex >= 0 &&
              hit.triangleIndex < _surface!.sourceCells.length
          ? _surface!.sourceCells[hit.triangleIndex]
          : null,
      'isosurfaceValue': _surface == null ? null : _threshold,
      'trilinearSourceValue': sample.value,
      'unit': unitJson(activeUnit),
      'value': _vectorMode
          ? vectors!.sample(hit.point - vectors!.x.origin).value?.length
          : (_surface != null ? _threshold : sample.value),
      'time': _vectorMode ? null : _time?.time,
      'pixelVisibility': 'unknown',
      'worldPosition': hit.point.storage,
    };
  }

  /// Join a shared viewport triangle pick to source data without asserting visibility.
  Map<String, Object?> sampleTriangle({
    required int runtimeObjectId,
    required int sceneRevision,
    required int triangleIndex,
    required Vec3 barycentric,
  }) {
    checkCurrent();
    final mesh = _mesh;
    if (mesh == null ||
        mesh.id != runtimeObjectId ||
        scene.revision != sceneRevision) {
      throw const ScientificViewException(
        ScientificViewFailure.stale,
        'Pick target or scene revision changed.',
      );
    }
    final geometry = mesh.geometry;
    if (geometry.topology != GeometryTopology.triangles) {
      throw StateError(
        'Use source-position sampling for line or volume representations.',
      );
    }
    if (triangleIndex < 0 ||
        triangleIndex >= geometry.indices.length ~/ 3 ||
        !barycentric.isFinite ||
        barycentric.storage.any((v) => v < 0 || v > 1) ||
        (barycentric.x + barycentric.y + barycentric.z - 1).abs() > 1e-9) {
      throw ArgumentError('Invalid triangle or barycentric coordinates.');
    }
    var point = Vec3.zero;
    for (var corner = 0; corner < 3; corner++) {
      final vertex = geometry.indices[triangleIndex * 3 + corner];
      point =
          point +
          Vec3.array(geometry.positions, vertex * 3) *
              barycentric.storage[corner];
    }
    final local = point + mesh.position - _grid.origin;
    return {
      ...sample(local),
      'viewRevision': revision,
      'sceneRevision': sceneRevision,
      'runtimeObjectId': runtimeObjectId,
      'triangleIndex': triangleIndex,
      'sourceCell': _surface?.sourceCells[triangleIndex],
      'isosurfaceValue': _surface == null ? null : _threshold,
      'method': 'caller-supplied-triangle-barycentrics',
    };
  }

  Map<String, Object?> describe() {
    checkCurrent();
    return {
      'viewId': id,
      'revision': revision,
      'representation': _mode.name,
      'sourceId': activeSource.id,
      'scalarSourceId': _grid.source.id,
      'vectorSourceId': vectors?.x.source.id,
      'sourceKind': activeSource.kind.name,
      'unit': unitJson(activeUnit),
      'coordinateUnit': unitJson(_grid.coordinateUnit),
      'dimensions': _vectorMode
          ? [vectors!.x.sizeX, vectors!.x.sizeY, vectors!.x.sizeZ]
          : [_grid.sizeX, _grid.sizeY, _grid.sizeZ],
      'missingSamples': _vectorMode
          ? vectors!.missingCount
          : _grid.missingCount,
      'runtimeObjectId': _mesh?.id,
      'sceneRevision': scene.revision,
      'threshold': _threshold,
      'sliceIndex': _index,
      'vectorScale': _vectorScale,
      'seed': _seed.storage,
      'volumeOpacity': _volumeOpacity,
      'volumeSampleDistance': _volumeStep,
      'transferMinimum': _transfer.minimum,
      'transferMaximum': _transfer.maximum,
      'time': _vectorMode ? null : _time?.time,
      'timeStatus': _vectorMode
          ? 'static-vector-field'
          : _time == null
          ? 'unavailable-static-field'
          : 'source-frames',
      'timeUnit': _vectorMode || _time == null
          ? null
          : unitJson(_time!.timeUnit),
      'frames': _vectorMode || _time == null
          ? null
          : [
              for (final f in _time!.frames)
                {'id': f.id, 'version': f.version, 'time': f.time},
            ],
      'cells': _surface?.sourceCells.length ?? _slice?.renderedCells,
      'omittedCells': _surface?.omittedCells ?? _slice?.omittedCells,
      'segments': _lines?.sourceSamples.length,
      'streamlineTermination': _streamline?.termination.name,
      'streamlineLength': _streamline?.length,
      'geometryBytes':
          _surface?.geometry?.byteLength ??
          _slice?.geometryBytes ??
          _lines?.geometry?.byteLength ??
          0,
      'maxCoordinateError':
          _surface?.maxCoordinateError ??
          _slice?.maxCoordinateError ??
          _lines?.maxCoordinateError,
      'empty': _mode == ScientificRepresentation.volume
          ? _grid.validCount == 0
          : _mesh == null,
      'volumeSampleCount': _mode == ScientificRepresentation.volume
          ? _grid.sampleCount
          : null,
      'volumeScalarError': _mode == ScientificRepresentation.volume
          ? volume?.maxScalarError
          : null,
      'volumeDepth': 'opaque-scene-depth',
      'pixelVisibility': 'unknown',
    };
  }

  Registration onDispose(void Function() action) {
    checkCurrent();
    _disposal.add(action);
    return Registration(() => _disposal.remove(action));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final action in List.of(_disposal)) {
      action();
    }
    _disposal.clear();
    await _queue;
    _mesh?.parent?.remove(_mesh!);
    _mesh = null;
    _slice = null;
    _surface = null;
    _lines = null;
    _streamline = null;
    _time = null;
    if (volume != null && !volume!.isClosed) await volume!.setVolume(null);
  }
}
