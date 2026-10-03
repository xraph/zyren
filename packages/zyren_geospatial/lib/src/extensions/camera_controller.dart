import 'package:zyren/zyren.dart';

import '../point_of_view.dart';

enum GeoCameraComponent { position, target, orientation, lens }

/// Implement on a scene plugin. Only its active attachment publishes a pose.
abstract interface class GeoCameraRig {
  GeospatialCameraPose get pose;
  void setActive(bool active);
  GeospatialCameraPose constrain(GeospatialCameraPose pose);
}

final class GeoCameraController {
  final void Function(GeospatialCameraPose)? validatePose;
  GeoCameraController({this.validatePose});
  final _rigs = <String, GeoCameraRig>{};
  final _modifiers = <String, _Modifier>{};
  String? _active;
  bool _publishing = false;
  String? get activeRigId => _active;
  List<String> get rigIds => List.unmodifiable(_rigs.keys.toList()..sort());
  void _checkEdit() {
    if (_publishing) {
      throw StateError(
        'Camera registrations cannot change during publication.',
      );
    }
  }

  Registration registerRig(String id, ScenePlugin rig) {
    _checkEdit();
    if (id.trim().isEmpty || _rigs.containsKey(id) || rig is! GeoCameraRig) {
      throw ArgumentError(
        'A rig needs a unique ID and the GeoCameraRig contract.',
      );
    }
    final entry = rig as GeoCameraRig;
    if (_rigs.values.any((value) => identical(value, entry))) {
      throw ArgumentError('A camera rig cannot register under two IDs.');
    }
    entry.setActive(false);
    _rigs[id] = entry;
    try {
      if (_active == null) activate(id);
    } catch (_) {
      _rigs.remove(id);
      rethrow;
    }
    return Registration(() {
      if (!identical(_rigs[id], entry)) return;
      entry.setActive(false);
      _rigs.remove(id);
      if (_active == id) {
        _active = null;
        if (_rigs.isNotEmpty) activate(rigIds.first);
      }
    });
  }

  void activate(String rigId) {
    _checkEdit();
    final next = _rigs[rigId];
    if (next == null) throw ArgumentError('Unknown camera rig $rigId.');
    if (_active == rigId) return;
    final previous = _rigs[_active];
    previous?.setActive(false);
    try {
      next.setActive(true);
      _active = rigId;
    } catch (_) {
      previous?.setActive(true);
      rethrow;
    }
  }

  Registration registerModifier(
    String id,
    int priority,
    GeospatialCameraPose Function(GeospatialCameraPose) modify, {
    Set<GeoCameraComponent> components = const {
      GeoCameraComponent.position,
      GeoCameraComponent.target,
      GeoCameraComponent.orientation,
      GeoCameraComponent.lens,
    },
  }) {
    _checkEdit();
    if (id.trim().isEmpty || _modifiers.containsKey(id)) {
      throw ArgumentError('Camera modifier IDs must be unique and nonempty.');
    }
    final entry = _Modifier(id, priority, modify, components);
    _modifiers[id] = entry;
    return Registration(() {
      if (identical(_modifiers[id], entry)) _modifiers.remove(id);
    });
  }

  bool publish(String rigId, Camera target) {
    if (_publishing) throw StateError('Camera publication cannot recurse.');
    if (_active != rigId) return false;
    final rig = _rigs[rigId]!;
    _publishing = true;
    try {
      var pose = rig.pose;
      final ordered = _modifiers.values.toList()
        ..sort((a, b) {
          final priority = a.priority.compareTo(b.priority);
          return priority == 0 ? a.id.compareTo(b.id) : priority;
        });
      for (final modifier in ordered) {
        final next = modifier.modify(pose);
        next.validate();
        if ((!modifier.components.contains(GeoCameraComponent.position) &&
                next.position != pose.position) ||
            (!modifier.components.contains(GeoCameraComponent.target) &&
                next.target != pose.target) ||
            (!modifier.components.contains(GeoCameraComponent.orientation) &&
                (next.up != pose.up || next.surfaceUp != pose.surfaceUp)) ||
            (!modifier.components.contains(GeoCameraComponent.lens) &&
                !identical(next.lens, pose.lens))) {
          throw StateError(
            'Camera modifier ${modifier.id} changed an undeclared component.',
          );
        }
        pose = next;
      }
      pose = rig.constrain(pose);
      pose.validate();
      validatePose?.call(pose);
      if (_active != rigId || !identical(_rigs[rigId], rig)) {
        throw StateError('Camera ownership changed during publication.');
      }
      pose.applyTo(target);
      return true;
    } finally {
      _publishing = false;
    }
  }
}

final class _Modifier {
  final String id;
  final int priority;
  final GeospatialCameraPose Function(GeospatialCameraPose) modify;
  final Set<GeoCameraComponent> components;
  _Modifier(
    this.id,
    this.priority,
    this.modify,
    Set<GeoCameraComponent> components,
  ) : components = Set.unmodifiable(components);
}
