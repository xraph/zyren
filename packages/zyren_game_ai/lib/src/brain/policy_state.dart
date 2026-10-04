part of '../../zyren_game_ai.dart';

/// Per-identity recurrent tensors. Native weights are owned by the shared ML cache.
final class PolicyState {
  final MlModelManifest model;
  final int maxBytes;
  MlTensorMap _tensors = const {};
  int _version = 0, _epoch = 0;
  int get epoch => _epoch;
  int get version => _version;
  MlTensorMap get tensors => _tensors;
  int get byteLength => _tensors.values.fold(0, (n, t) => n + t.byteLength);
  PolicyState(this.model, {this.maxBytes = 1048576}) {
    _bounded(maxBytes, 1048576, 'maxHiddenBytes');
    reset();
  }
  bool accepts(MlTensorMap next) {
    if (next.length != model.recurrent.length ||
        next.values.fold<int>(0, (n, t) => n + t.byteLength) > maxBytes) {
      return false;
    }
    for (final input in model.recurrent.keys) {
      final spec = model.inputs.firstWhere((s) => s.name == input);
      final tensor = next[input];
      if (tensor == null ||
          !_sameShape(tensor.shape, _actorShape(spec)) ||
          !spec.accepts(tensor)) {
        return false;
      }
    }
    return true;
  }

  bool _commit(MlTensorMap next, int expectedVersion) {
    if (expectedVersion != version || !accepts(next)) return false;
    _tensors = Map.unmodifiable(next);
    _version++;
    return true;
  }

  PolicyStateSnapshot snapshot() =>
      PolicyStateSnapshot._(model.sha256, version, tensors);

  void validateSnapshot(PolicyStateSnapshot snapshot) {
    if (snapshot.modelHash != model.sha256 || !accepts(snapshot.tensors)) {
      throw ArgumentError('Incompatible recurrent state snapshot.');
    }
  }

  void restoreSnapshot(PolicyStateSnapshot snapshot) {
    validateSnapshot(snapshot);
    _tensors = snapshot.tensors;
    _version = snapshot.version;
    _epoch++;
  }

  void _invalidateEpoch() => _epoch++;

  static List<int> _actorShape(MlTensorSpec spec) {
    final shape = spec.shape;
    // ONNX LSTM tensors are [layers,batch,width]. Each actor owns one batch.
    if (shape.length == 3 &&
        shape[0] == 1 &&
        shape[1] == -1 &&
        shape[2] > 0 &&
        spec.dtype == MlDtype.float32) {
      return [1, 1, shape[2]];
    }
    if (shape.length < 2 ||
        shape.skip(1).any((d) => d < 1) ||
        (shape.first != -1 && shape.first != 1)) {
      throw ArgumentError('Unsupported per-actor recurrent shape.');
    }
    return [1, ...shape.skip(1)];
  }

  static bool _sameShape(List<int> a, List<int> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => i).every((i) => a[i] == b[i]);

  void reset() {
    final next = <String, MlTensor>{};
    var bytes = 0;
    for (final key in model.recurrent.keys) {
      final spec = model.inputs.firstWhere((s) => s.name == key);
      final shape = _actorShape(spec);
      bytes += mlTensorByteLength(spec.dtype, shape);
      if (bytes > maxBytes) {
        throw ArgumentError('Recurrent state exceeds actor budget.');
      }
      next[key] = MlTensor(
        spec.dtype,
        shape,
        Uint8List(mlTensorByteLength(spec.dtype, shape)),
      );
    }
    _tensors = Map.unmodifiable(next);
    _version = 0;
    _epoch++;
  }
}
