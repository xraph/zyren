import 'package:zyren/zyren.dart';

import 'models.dart';

/// Host-owned source identity attached to an ordinary scene object.
final class XrAnchorBinding {
  final String anchorId;
  final String? sourceId;
  final Object3D object;
  final Group _placement;
  bool _observed = false;
  XrAnchorBinding._(this.anchorId, this.sourceId, this.object, this._placement);
  int get runtimeObjectId => object.id;
  bool get tracked => _placement.visible;
}

/// Places ordinary scene objects under native anchors without owning their GPU
/// resources. Reset removes bindings; lost tracking hides them until recovery.
final class XrSceneBindings {
  final String sessionId;
  final Object3D root;
  final _bindings = <String, XrAnchorBinding>{};
  int _originEpoch, _lastRevision = -1;
  bool _disposed = false;
  XrSceneBindings({
    required this.sessionId,
    required this.root,
    required int originEpoch,
  }) : _originEpoch = originEpoch {
    if (sessionId.isEmpty || originEpoch < 0) {
      throw ArgumentError('A session identity and origin epoch are required.');
    }
  }

  List<XrAnchorBinding> get bindings => List.unmodifiable(_bindings.values);

  XrAnchorBinding bind({
    required String anchorId,
    required Object3D object,
    String? sourceId,
  }) {
    _checkOpen();
    if (anchorId.isEmpty || sourceId == '' || _bindings.containsKey(anchorId)) {
      throw ArgumentError('Use a unique anchor ID and a nonempty source ID.');
    }
    if (object.parent != null || identical(object, root)) {
      throw ArgumentError('Detach the object before assigning its XR owner.');
    }
    for (
      Object3D? ancestor = root;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (identical(ancestor, object)) {
        throw ArgumentError('An XR binding cannot contain its scene root.');
      }
    }
    if (_bindings.length >= 128) {
      throw const XrException('anchorLimit', 'Scene anchor bindings are full.');
    }
    final placement = Group(name: 'xr:$anchorId')..visible = false;
    placement.add(object);
    root.add(placement);
    final binding = XrAnchorBinding._(anchorId, sourceId, object, placement);
    _bindings[anchorId] = binding;
    return binding;
  }

  /// Returns removed anchor IDs. The native snapshot supplies session identity
  /// and origin epoch; neither is an application source ID.
  List<String> update(XrSnapshot snapshot, {XrPose? sceneFromSession}) {
    _checkOpen();
    final originEpoch = snapshot.originEpoch;
    if (snapshot.sessionId != sessionId ||
        originEpoch < _originEpoch ||
        snapshot.revision < _lastRevision) {
      throw const XrException('staleOrigin', 'The binding origin is stale.');
    }
    // A rigid root keeps the session's metre scale and avoids lossy shear.
    XrPose(root.worldMatrix.storage);
    final rootFromSession =
        root.worldMatrix.inverted() *
        Mat4((sceneFromSession ?? XrPose.identity()).matrix);
    if (originEpoch != _originEpoch) {
      final removed = _bindings.keys.toList();
      for (final id in removed) {
        unbind(id);
      }
      _originEpoch = originEpoch;
      _lastRevision = snapshot.revision;
      return removed;
    }
    _lastRevision = snapshot.revision;
    final frame = snapshot.frame;
    if (snapshot.state != XrSessionState.running ||
        frame == null ||
        frame.tracking != XrTrackingState.normal ||
        frame.ageAt(snapshot.nativeTimestamp) > .5) {
      for (final binding in _bindings.values) {
        binding._placement.visible = false;
      }
      return const [];
    }
    final anchors = {for (final anchor in frame.anchors) anchor.id: anchor};
    final removed = <String>[];
    for (final binding in _bindings.values.toList()) {
      final anchor = anchors[binding.anchorId];
      if (anchor == null) {
        binding._placement.visible = false;
        if (binding._observed) {
          removed.add(binding.anchorId);
          unbind(binding.anchorId);
        }
        continue;
      }
      binding._observed = true;
      if (anchor.tracking != XrTrackingState.normal) {
        binding._placement.visible = false;
        continue;
      }
      final matrix = rootFromSession * Mat4(anchor.pose.matrix);
      final position = Vec3.zero.toVectorMath();
      final rotation = Quat.identity.toVectorMath();
      final scale = Vec3.one.toVectorMath();
      matrix.toVectorMath().decompose(position, rotation, scale);
      binding._placement
        ..position = Vec3.fromVectorMath(position)
        ..quaternion = Quat.fromVectorMath(rotation)
        ..visible = true;
    }
    return List.unmodifiable(removed);
  }

  Object3D? unbind(String anchorId) {
    _checkOpen();
    final binding = _bindings.remove(anchorId);
    if (binding == null) return null;
    binding._placement.remove(binding.object);
    root.remove(binding._placement);
    return binding.object;
  }

  void dispose() {
    if (_disposed) return;
    for (final id in _bindings.keys.toList()) {
      unbind(id);
    }
    _disposed = true;
  }

  void _checkOpen() {
    if (_disposed) throw StateError('XR scene bindings are disposed.');
  }
}
