import 'package:zyren/zyren.dart';

import 'scalar_grid.dart';
import 'scalar_slice.dart';
import 'transfer_function.dart';
import 'history.dart';

enum ScientificViewFailure { unavailable, stale }

final class ScientificViewException implements Exception {
  final ScientificViewFailure reason;
  final String message;
  const ScientificViewException(this.reason, this.message);
  @override
  String toString() => 'ScientificViewException(${reason.name}): $message';
}

/// Owns one slice in a scene. Changes build and validate before replacing a mesh.
/// Host UI and agent adapters use the same revision-checked operations.
final class ScientificSliceView {
  final String id;
  final Scene scene;
  final double coordinateTolerance;
  final ScientificBudget budget;
  ScalarSlice _slice;
  Mesh? _mesh;
  int _revision = 0, _meshRevision = 0;
  bool _disposed = false;
  final _disposal = <void Function()>[];
  late final ScientificHistory<
    ({SliceAxis axis, double index, ScalarTransferFunction transfer})
  >
  _history;

  ScientificSliceView({
    required this.id,
    required this.scene,
    required ScalarSlice slice,
    required this.coordinateTolerance,
    ScientificBudget? budget,
    int historyLimit = 32,
    int historyByteLimit = 32 * 1024 * 1024,
  }) : _slice = slice,
       budget = budget ?? ScientificBudget() {
    _history = ScientificHistory(
      limit: historyLimit,
      byteLimit: historyByteLimit,
      payloadBytes: (state) => state.transfer.stops.length * 32 + 128,
    );
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$').hasMatch(id) ||
        !coordinateTolerance.isFinite ||
        coordinateTolerance < 0 ||
        slice.maxCoordinateError > coordinateTolerance ||
        slice.width * slice.height > this.budget.maxSamples ||
        (slice.width - 1) * (slice.height - 1) > this.budget.maxSliceCells ||
        slice.geometryBytes > this.budget.maxGeometryBytes) {
      throw ArgumentError('Invalid view ID or coordinate tolerance.');
    }
    _mesh = slice.createMesh();
    if (_mesh case final mesh?) scene.add(mesh);
    _meshRevision = _mesh?.revision ?? 0;
  }

  bool get canUndo => !_disposed && _history.canUndo;
  bool get canRedo => !_disposed && _history.canRedo;
  Map<String, Object?> get history => _history.describe();
  ({SliceAxis axis, double index, ScalarTransferFunction transfer})
  _capture() =>
      (axis: _slice.axis, index: _slice.index, transfer: _slice.transfer);

  bool undo({required int expectedRevision}) =>
      _moveHistory(false, expectedRevision);
  bool redo({required int expectedRevision}) =>
      _moveHistory(true, expectedRevision);
  bool _moveHistory(bool redo, int expectedRevision) {
    checkCurrent(expectedRevision: expectedRevision);
    if (redo ? !canRedo : !canUndo) return false;
    final next = _history.target(redo);
    _replace(
      ScalarSlice.build(
        grid: _slice.grid,
        transfer: next.transfer,
        axis: next.axis,
        index: next.index,
        coordinateTolerance: coordinateTolerance,
        budget: budget,
      ),
      recordHistory: false,
    );
    _history.move(redo);
    return true;
  }

  void clearHistory({required int expectedRevision}) {
    checkCurrent(expectedRevision: expectedRevision);
    _history.clear();
    _revision++;
  }

  int get revision => _revision;
  bool get isDisposed => _disposed;
  ScalarSlice get slice => _slice;
  Mesh? get mesh => _mesh;

  void checkCurrent({int? expectedRevision}) {
    if (_disposed) {
      throw const ScientificViewException(
        ScientificViewFailure.unavailable,
        'Slice view is disposed.',
      );
    }
    if ((expectedRevision != null && expectedRevision != revision) ||
        (_mesh != null &&
            (_mesh!.parent != scene || _mesh!.revision != _meshRevision))) {
      throw const ScientificViewException(
        ScientificViewFailure.stale,
        'Slice view revision or scene object changed.',
      );
    }
  }

  void setSlice({
    required SliceAxis axis,
    required double index,
    required int expectedRevision,
  }) {
    checkCurrent(expectedRevision: expectedRevision);
    if (axis == _slice.axis && index == _slice.index) return;
    _replace(
      ScalarSlice.build(
        grid: _slice.grid,
        transfer: _slice.transfer,
        axis: axis,
        index: index,
        coordinateTolerance: coordinateTolerance,
        budget: budget,
      ),
    );
  }

  void setTransfer(
    ScalarTransferFunction transfer, {
    required int expectedRevision,
  }) {
    checkCurrent(expectedRevision: expectedRevision);
    _replace(
      ScalarSlice.build(
        grid: _slice.grid,
        transfer: transfer,
        axis: _slice.axis,
        index: _slice.index,
        coordinateTolerance: coordinateTolerance,
        budget: budget,
      ),
    );
  }

  void _replace(ScalarSlice next, {bool recordHistory = true}) {
    final before = _capture();
    final nextMesh = next.createMesh();
    scene.batch(() {
      if (_mesh case final previous?) scene.remove(previous);
      if (nextMesh != null) scene.add(nextMesh);
    });
    _slice = next;
    _mesh = nextMesh;
    _meshRevision = nextMesh?.revision ?? 0;
    _revision++;
    if (recordHistory) {
      _history.record(
        before,
        _capture(),
        before.axis != next.axis || before.index != next.index
            ? 'Change slice'
            : 'Change transfer',
      );
    }
  }

  /// Sample the actual picked triangle with its frozen barycentric weights.
  /// Viewport/frame evidence comes from the host's shared viewport provider.
  Map<String, Object?> inspectHit(
    PickResult hit, {
    required int expectedRevision,
  }) {
    checkCurrent(expectedRevision: expectedRevision);
    if (!identical(hit.object, _mesh) || hit.sceneRevision != scene.revision) {
      throw const ScientificViewException(
        ScientificViewFailure.stale,
        'Hit is from another object or an older scene revision.',
      );
    }
    return {
      ...sampleTriangle(
        triangleIndex: hit.triangleIndex,
        barycentric: hit.barycentric,
        runtimeObjectId: hit.object.id,
        expectedSceneRevision: hit.sceneRevision,
        expectedRevision: expectedRevision,
      ),
      'worldPosition': hit.point.storage,
      'method': 'cpu-triangle-geometry',
    };
  }

  /// Samples host-supplied triangle coordinates, for joining a shared viewport
  /// pick to this field. This call does not itself establish a screen hit.
  Map<String, Object?> sampleTriangle({
    required int triangleIndex,
    required Vec3 barycentric,
    required int runtimeObjectId,
    required int expectedSceneRevision,
    required int expectedRevision,
  }) {
    checkCurrent(expectedRevision: expectedRevision);
    if (_mesh == null ||
        runtimeObjectId != _mesh!.id ||
        expectedSceneRevision != scene.revision) {
      throw const ScientificViewException(
        ScientificViewFailure.stale,
        'Triangle target or scene revision changed.',
      );
    }
    final indices = _slice.geometry!.indices;
    if (triangleIndex < 0 ||
        triangleIndex >= indices.length ~/ 3 ||
        !barycentric.isFinite ||
        barycentric.storage.any((v) => v < 0 || v > 1) ||
        (barycentric.x + barycentric.y + barycentric.z - 1).abs() > 1e-9) {
      throw ArgumentError('Invalid triangle or barycentric coordinates.');
    }
    final base = triangleIndex * 3;
    final weights = barycentric.storage;
    var value = 0.0;
    final sampleIndices = <int>[];
    for (var corner = 0; corner < 3; corner++) {
      final vertex = indices[base + corner];
      sampleIndices.add(vertex);
      value +=
          _slice.valueAt(vertex % _slice.width, vertex ~/ _slice.width)! *
          weights[corner];
    }
    if (!value.isFinite) {
      throw ArgumentError(
        'Triangle interpolation exceeds finite scalar range.',
      );
    }
    return {
      'datasetId': _slice.grid.source.id,
      'viewId': id,
      'runtimeObjectId': runtimeObjectId,
      'sceneRevision': expectedSceneRevision,
      'viewRevision': revision,
      'sourceKind': _slice.grid.source.kind.name,
      'value': value,
      'unit': unitJson(_slice.grid.valueUnit),
      'missing': false,
      'time': null,
      'timeStatus': 'unavailable-static-field',
      'interpolation': 'linear-plane-then-triangle-barycentric',
      'sampleIndices': sampleIndices,
      'triangleIndex': triangleIndex,
      'coordinateUnit': unitJson(_slice.grid.coordinateUnit),
      'method': 'caller-supplied-triangle-barycentrics',
      'pixelVisibility': 'unknown',
      'coverage':
          'Slice geometry and missing-cell holes; no pixel visibility assertion.',
      'actions': ['set_slice', 'set_transfer'],
    };
  }

  Map<String, Object?> describe() {
    checkCurrent();
    final grid = _slice.grid;
    return {
      'viewId': id,
      'viewRevision': revision,
      'sceneRevision': scene.revision,
      'runtimeObjectId': _mesh?.id,
      'history': history,
      'dataset': {
        'sourceId': grid.source.id,
        'sourceKind': grid.source.kind.name,
        'description': grid.source.description,
        'name': grid.name,
        'dimensions': [grid.sizeX, grid.sizeY, grid.sizeZ],
        'origin': grid.origin.storage,
        'spacing': grid.spacing.storage,
        'unit': unitJson(grid.valueUnit),
        'coordinateUnit': unitJson(grid.coordinateUnit),
        'validSamples': grid.validCount,
        'missingSamples': grid.missingCount,
        'minimum': grid.range?.minimum,
        'maximum': grid.range?.maximum,
        'payloadBytes': grid.payloadBytes,
      },
      'slice': {
        'axis': _slice.axis.name,
        'index': _slice.index,
        'width': _slice.width,
        'height': _slice.height,
        'renderedCells': _slice.renderedCells,
        'omittedCells': _slice.omittedCells,
        'geometryBytes': _slice.geometryBytes,
        'maxCoordinateError': _slice.maxCoordinateError,
        'coordinateTolerance': coordinateTolerance,
        'belowRangeSamples': _slice.belowRangeSamples,
        'aboveRangeSamples': _slice.aboveRangeSamples,
      },
      'transfer': {
        'minimum': _slice.transfer.minimum,
        'maximum': _slice.transfer.maximum,
        'unit': unitJson(_slice.transfer.unit),
        'outsideRange': 'clamp',
        'colorSpace': 'linear-rgb',
        'stops': [
          for (final stop in _slice.transfer.stops)
            {'position': stop.position, 'rgb': stop.color.toList()},
        ],
      },
      'missingPolicy': 'null-samples-omit-any-affected-cell',
      'interpolation': 'linear-between-grid-planes; colors-mapped-at-vertices',
      'time': null,
      'timeStatus': 'unavailable-static-field',
    };
  }

  Registration onDispose(void Function() callback) {
    checkCurrent();
    _disposal.add(callback);
    return Registration(() => _disposal.remove(callback));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _history.clear();
    if (_mesh case final mesh?) {
      mesh.parent?.remove(mesh);
    }
    _mesh = null;
    for (final callback in List.of(_disposal)) {
      callback();
    }
    _disposal.clear();
  }
}

Map<String, Object?> unitJson(ScientificUnit unit) => {
  'quantity': unit.quantity,
  'symbol': unit.symbol,
};
