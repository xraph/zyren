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
          tensor.shape.firstOrNull != 1 ||
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

  void reset() {
    final next = <String, MlTensor>{};
    var bytes = 0;
    for (final key in model.recurrent.keys) {
      final spec = model.inputs.firstWhere((s) => s.name == key);
      if (spec.shape.length < 2 || spec.shape.skip(1).any((d) => d < 1)) {
        throw ArgumentError(
          'Only the recurrent batch dimension may be dynamic.',
        );
      }
      final shape = [1, ...spec.shape.skip(1)];
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
