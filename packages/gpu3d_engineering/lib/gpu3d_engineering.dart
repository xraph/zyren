library;

import 'dart:async';
import 'dart:convert';
import 'package:gpu3d/gpu3d.dart';

part 'src/document.dart';

const sceneEngineering = ServiceKey<SceneEngineeringPlugin>(
  'gpu3d.engineering',
);

/// Storage belongs to the host. A missing document returns null.
abstract interface class EngineeringStore {
  Future<String?> read();
  Future<void> write(String document);
}

/// Stable review records with explicit bindings to one attached scene.
class SceneEngineeringPlugin extends ScenePlugin {
  @override
  String get id => 'gpu3d.engineering';
  final bool Function(Object3D)? excludeFromIsolation;
  EngineeringDocument _document;
  final _bindings = <String, Object3D>{};
  final _visibility = <Object3D, (bool, bool)>{};
  final _changes = StreamController<void>.broadcast();
  Set<String> _isolated = const {};
  PluginContext? _context;
  int _revision = 0, _savedRevision = -1, _lifetime = 0;
  bool _busy = false;

  SceneEngineeringPlugin({
    required EngineeringDocument document,
    this.excludeFromIsolation,
  }) : _document = document;

  EngineeringDocument get document => _document;
  Stream<void> get changes => _changes.stream;
  bool get hasUnsavedChanges => _revision != _savedRevision;
  bool get isBusy => _busy;
  bool get isAttached => _context != null;
  Set<String> get isolatedIds => _isolated;
  PluginContext get _attached =>
      _context ??
      (throw StateError('Attach engineering before using scene bindings.'));

  @override
  void attach(PluginContext context) {
    _context = context;
    _lifetime++;
    context.provide(sceneEngineering, this);
    context.scope.listen(context.scene.changes, (_) {
      final removed = _bindings.keys
          .where((id) => !_contains(_bindings[id]!))
          .toList();
      if (removed.isEmpty) return;
      if (removed.any(_isolated.contains)) restoreVisibility();
      for (final id in removed) {
        _bindings.remove(id);
      }
      _notify();
    });
  }

  bool _contains(Object3D object) {
    final scene = _attached.scene;
    for (Object3D? node = object.parent; node != null; node = node.parent) {
      if (identical(node, scene)) return true;
    }
    return false;
  }

  /// Bind a source ID after each import. Names and runtime inspector IDs are not keys.
  void bind(String id, Object3D object) {
    if (!_document.objects.containsKey(id)) {
      throw ArgumentError('No engineering record for $id.');
    }
    if (!_contains(object)) {
      throw ArgumentError('Bind an object from the attached scene.');
    }
    final prior = objectFor(id);
    if (prior != null && !identical(prior, object)) {
      throw StateError('ID $id is already bound.');
    }
    final otherId = idFor(object);
    if (otherId != null && otherId != id) {
      throw StateError('Object is already bound to $otherId.');
    }
    _bindings[id] = object;
    _notify();
  }

  void unbind(String id) {
    _attached;
    if (_isolated.contains(id)) restoreVisibility();
    if (_bindings.remove(id) != null) _notify();
  }

  Object3D? objectFor(String id) {
    final object = _bindings[id];
    return object != null && _contains(object) ? object : null;
  }

  String? idFor(Object3D object) {
    if (!_contains(object)) return null;
    for (final entry in _bindings.entries) {
      if (identical(entry.value, object)) return entry.key;
    }
    return null;
  }

  void putObject(EngineeringObject record) => _replace(
    EngineeringDocument(
      id: _document.id,
      objects: {..._document.objects, record.id: record}.values,
      annotations: _document.annotations.values,
    ),
  );

  void putAnnotation(EngineeringAnnotation annotation) => _replace(
    EngineeringDocument(
      id: _document.id,
      objects: _document.objects.values,
      annotations: {..._document.annotations, annotation.id: annotation}.values,
    ),
  );

  void removeAnnotation(String id) {
    if (!_document.annotations.containsKey(id)) return;
    _replace(
      EngineeringDocument(
        id: _document.id,
        objects: _document.objects.values,
        annotations: _document.annotations.values.where(
          (note) => note.id != id,
        ),
      ),
    );
  }

  void _replace(EngineeringDocument next) {
    _document = next;
    _revision++;
    _notify();
  }

  /// Converts a picked world point into a persistent object-local anchor.
  Vec3 localAnchor(String objectId, Vec3 world) {
    if (!world.isFinite) throw ArgumentError('Anchor must be finite.');
    final object =
        objectFor(objectId) ??
        (throw StateError('Object $objectId is not bound.'));
    return _point(_world(object).inverted(), world);
  }

  /// Unbound annotations remain in the document and have no current world point.
  Vec3? worldAnchor(String annotationId) {
    final note =
        _document.annotations[annotationId] ??
        (throw ArgumentError('Unknown annotation $annotationId.'));
    final object = objectFor(note.objectId);
    return object == null ? null : _point(_world(object), note.anchor);
  }

  /// Captures visibility for the current hierarchy. Helpers can be excluded.
  void isolate(Set<String> ids) {
    final context = _attached;
    if (ids.isEmpty) {
      throw ArgumentError('Choose at least one object to isolate.');
    }
    final targets = {
      for (final id in ids)
        objectFor(id) ?? (throw StateError('Object $id is not bound.')),
    };
    final paths = <Object3D>{};
    for (final target in targets) {
      for (Object3D? node = target; node != null; node = node.parent) {
        paths.add(node);
      }
    }
    // Evaluate host predicates before changing any visibility.
    final desired = <Object3D, bool>{};
    void visit(Object3D object) {
      if (excludeFromIsolation?.call(object) ?? false) return;
      desired[object] = paths.contains(object);
      if (targets.contains(object) || !paths.contains(object)) return;
      for (final child in object.children) {
        visit(child);
      }
    }

    for (final child in context.scene.children) {
      visit(child);
    }
    context.scene.batch(() {
      restoreVisibility();
      for (final entry in desired.entries) {
        _visibility[entry.key] = (entry.key.visible, entry.value);
        entry.key.visible = entry.value;
      }
      _isolated = Set.unmodifiable(ids);
    });
    _notify();
  }

  void restoreVisibility() {
    for (final entry in _visibility.entries) {
      if (entry.key.visible == entry.value.$2) {
        entry.key.visible = entry.value.$1;
      }
    }
    _visibility.clear();
    _isolated = const {};
    _notify();
  }

  /// Replaces data only after a complete read, validation and stale-read check.
  Future<bool> load(EngineeringStore store) async {
    if (_busy) {
      throw StateError('A review storage operation is already running.');
    }
    final revision = _revision, lifetime = _lifetime;
    _busy = true;
    _notify();
    try {
      final source = await store.read();
      if (source == null) return false;
      final next = EngineeringDocument.decode(source);
      if (next.id != _document.id) {
        throw const FormatException('Review belongs to another document.');
      }
      if (revision != _revision || lifetime != _lifetime) {
        throw StateError(
          'Review changed while loading. Current edits were kept.',
        );
      }
      restoreVisibility();
      _bindings.removeWhere((id, _) => !next.objects.containsKey(id));
      _replace(next);
      _savedRevision = _revision;
      return true;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> save(EngineeringStore store) async {
    if (_busy) {
      throw StateError('A review storage operation is already running.');
    }
    final revision = _revision, lifetime = _lifetime;
    final source = _document.encode();
    _busy = true;
    _notify();
    try {
      await store.write(source);
      if (lifetime == _lifetime) _savedRevision = revision;
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _notify() {
    _changes.add(null);
    _context?.invalidate();
  }

  @override
  void detach(PluginContext context) {
    restoreVisibility();
    _bindings.clear();
    _lifetime++;
    _context = null;
  }
}

Mat4 _world(Object3D object) => object.parent == null
    ? object.localMatrix
    : _world(object.parent!) * object.localMatrix;
Vec3 _point(Mat4 matrix, Vec3 point) {
  final m = matrix.storage;
  final value = Vec3(
    m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
    m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
    m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14],
  );
  if (!value.isFinite) {
    throw ArgumentError('Anchor exceeds the transform range.');
  }
  return value;
}
