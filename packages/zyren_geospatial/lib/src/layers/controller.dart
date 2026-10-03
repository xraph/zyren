import 'dart:async';
import 'package:zyren/zyren.dart';
import 'layer.dart';
import 'change.dart';
import 'selection.dart';

/// Headless layer state. Each transaction publishes one immutable revision.
final class GeoLayerController {
  List<GeoLayer> _snapshot = const [];
  Map<String, Object> _identities = {};
  final _loads = <String, Object>{};
  GeoSelection _selection = GeoSelection([]);
  int _revision = 0;
  bool _editing = false, _closed = false;
  final _changes = StreamController<GeoLayerChange>.broadcast();
  int get revision => _revision;
  List<GeoLayer> get snapshot => _snapshot;
  GeoSelection get selection => _selection;
  Stream<GeoLayerChange> get changes => _changes.stream;
  bool get isDisposed => _closed;

  GeoLayer layer(String id) => _snapshot.firstWhere(
    (layer) => layer.id == id,
    orElse: () => throw ArgumentError.value(id, 'id', 'Unknown layer'),
  );

  void transact(int expectedRevision, void Function(GeoLayerEdit) operation) {
    if (_closed) throw StateError('Layer controller has closed.');
    if (_editing) {
      throw StateError('Nested layer transactions are not supported.');
    }
    if (expectedRevision != revision) {
      throw StateError(
        'Layer revision $expectedRevision is stale; current is $revision.',
      );
    }
    final edit = GeoLayerEdit._(
      List.of(_snapshot),
      Map.of(_identities),
      _selection.snapshot.toSet(),
    );
    _editing = true;
    try {
      operation(edit);
      edit.validate();
      final before = {for (final layer in _snapshot) layer.id: layer};
      final next = edit._ordered();
      final after = {for (final layer in next) layer.id: layer};
      final removed = before.keys.toSet().difference(after.keys.toSet());
      final added = after.keys.toSet().difference(before.keys.toSet());
      final oldIndices = {
        for (var i = 0; i < _snapshot.length; i++) _snapshot[i].id: i,
      };
      final newIndices = {for (var i = 0; i < next.length; i++) next[i].id: i};
      final updated = after.keys
          .where(
            (id) =>
                before.containsKey(id) &&
                (!identical(before[id], after[id]) ||
                    oldIndices[id] != newIndices[id]),
          )
          .toSet();
      _loads.removeWhere(
        (id, _) =>
            !identical(_identities[id], edit._identities[id]) ||
            before[id]?.sourceReference != after[id]?.sourceReference ||
            before[id]?.sourceRevision != after[id]?.sourceRevision,
      );
      _snapshot = List.unmodifiable(next);
      _identities = edit._identities;
      _selection = GeoSelection(edit._selection);
      _revision++;
      _changes.add(
        GeoLayerChange(
          previousRevision: _revision - 1,
          revision: _revision,
          snapshot: _snapshot,
          selection: _selection.snapshot,
          addedIds: added,
          removedIds: removed,
          updatedIds: updated,
        ),
      );
    } finally {
      edit._closed = true;
      _editing = false;
    }
  }

  void setVisible(String id, bool value) =>
      transact(revision, (e) => e.setVisible(id, value));
  bool effectiveVisible(String id) =>
      _ancestors(id).every((layer) => layer.visible);
  bool visibleAt(
    String id, {
    required double distance,
    required double metresPerPixel,
    required DateTime time,
  }) => _ancestors(id).every(
    (layer) =>
        layer.visible &&
        layer.filter.matches(
          distance: distance,
          metresPerPixel: metresPerPixel,
          time: time,
        ),
  );
  double effectiveOpacity(String id) =>
      _ancestors(id).fold(1, (value, layer) => value * layer.opacity);
  bool effectiveQueryable(String id) {
    final target = layer(id);
    return target.capabilities.contains(GeoLayerCapability.query) &&
        _ancestors(id).every((layer) => layer.queryable) &&
        (target.policies.queryWhenHidden || effectiveVisible(id));
  }

  Iterable<GeoLayer> _ancestors(String id) sync* {
    var current = layer(id);
    while (true) {
      yield current;
      if (current.parentId == null) break;
      current = layer(current.parentId!);
    }
  }

  Registration register(GeoLayer value) {
    transact(revision, (e) => e.add(value));
    final identity = _identities[value.id];
    return Registration(() {
      if (_closed || !identical(_identities[value.id], identity)) return;
      // A foreign layer can outlive this registration. Keep it under the old
      // parent rather than deleting another extension's content.
      transact(revision, (e) {
        for (final child in _snapshot.where(
          (layer) => layer.parentId == value.id,
        )) {
          e.reparent(child.id, layer(value.id).parentId);
        }
        e.remove(value.id);
      });
    });
  }

  GeoLayerLoad beginLoad(String id) {
    layer(id);
    final generation = Object();
    transact(
      revision,
      (e) => e.setStatus(
        id,
        GeoLayerStatus(
          lifecycle: layer(id).status.lifecycle,
          data: GeoLayerDataState.loading,
          coverage: layer(id).status.coverage,
          attribution: layer(id).status.attribution,
        ),
      ),
    );
    _loads[id] = generation;
    return GeoLayerLoad._(this, id, generation, _identities[id]!);
  }

  Future<void> dispose() {
    if (_editing) {
      throw StateError('Cannot dispose a layer controller during an edit.');
    }
    if (_closed) return _changes.done;
    _closed = true;
    _loads.clear();
    return _changes.close();
  }
}

/// One source generation can publish until it is cancelled, replaced or removed.
final class GeoLayerLoad {
  final GeoLayerController _controller;
  final String layerId;
  final Object _generation, _identity;
  GeoLayerLoad._(
    this._controller,
    this.layerId,
    this._generation,
    this._identity,
  );
  bool get isCurrent =>
      !_controller._closed &&
      identical(_controller._loads[layerId], _generation) &&
      identical(_controller._identities[layerId], _identity);
  bool publish(GeoLayerStatus status) {
    if (!isCurrent) return false;
    _controller.transact(
      _controller.revision,
      (e) => e.setStatus(layerId, status),
    );
    return true;
  }

  void cancel() {
    if (isCurrent) _controller._loads.remove(layerId);
  }
}

final class GeoLayerEdit {
  final List<GeoLayer> _layers;
  final Map<String, Object> _identities;
  final Set<GeoFeatureId> _selection;
  bool _closed = false;
  GeoLayerEdit._(this._layers, this._identities, this._selection);
  void _requireOpen() {
    if (_closed) throw StateError('Layer edit has ended.');
  }

  int _index(String id) {
    _requireOpen();
    final index = _layers.indexWhere((layer) => layer.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id', 'Unknown layer');
    return index;
  }

  GeoLayer _layer(String id) => _layers[_index(id)];
  void _replace(String id, GeoLayer value) => _layers[_index(id)] = value;

  void add(GeoLayer layer) {
    _requireOpen();
    if (_identities.containsKey(layer.id)) {
      throw ArgumentError('Duplicate layer ${layer.id}.');
    }
    _layers.add(layer);
    _identities[layer.id] = Object();
  }

  void replaceAll(Iterable<GeoLayer> values) {
    _requireOpen();
    final previous = {for (final layer in _layers) layer.id: layer};
    final identities = Map<String, Object>.of(_identities);
    final candidate = values.toList();
    _layers.clear();
    _identities.clear();
    for (final layer in candidate) {
      add(layer);
      if (previous[layer.id]?.owner == layer.owner &&
          previous[layer.id]?.kind == layer.kind) {
        _identities[layer.id] = identities[layer.id]!;
      }
    }
    _selection.removeWhere(
      (feature) => !_identities.containsKey(feature.layerId),
    );
  }

  void clear() {
    _requireOpen();
    _layers.clear();
    _identities.clear();
    _selection.clear();
  }

  void remove(String id, {bool descendants = false}) {
    _index(id);
    final removed = {id};
    for (var changed = true; changed;) {
      changed = false;
      for (final layer in _layers) {
        if (removed.contains(layer.parentId) && !removed.contains(layer.id)) {
          if (!descendants) throw ArgumentError('Layer $id has children.');
          removed.add(layer.id);
          changed = true;
        }
      }
    }
    _layers.removeWhere((layer) => removed.contains(layer.id));
    _identities.removeWhere((id, _) => removed.contains(id));
    _selection.removeWhere((id) => removed.contains(id.layerId));
  }

  void reparent(String id, String? parentId) => _replace(
    id,
    _layer(id).copyWith(parentId: parentId, clearParent: parentId == null),
  );
  void move(String id, int siblingIndex) {
    final value = _layer(id);
    if (!value.isGroup &&
        !value.capabilities.contains(GeoLayerCapability.reorder)) {
      throw ArgumentError('Layer $id does not support reordering.');
    }
    final siblings = _layers
        .where((layer) => layer.parentId == value.parentId)
        .toList();
    if (siblingIndex < 0 || siblingIndex >= siblings.length) {
      throw ArgumentError('Invalid sibling index $siblingIndex.');
    }
    siblings.remove(value);
    siblings.insert(siblingIndex, value);
    var cursor = 0;
    for (var i = 0; i < _layers.length; i++) {
      if (_layers[i].parentId == value.parentId) {
        _layers[i] = siblings[cursor++];
      }
    }
  }

  void setVisible(String id, bool visible) =>
      _replace(id, _layer(id).copyWith(visible: visible));
  void setQueryable(String id, bool queryable) {
    final value = _layer(id);
    if (queryable &&
        !value.isGroup &&
        !value.capabilities.contains(GeoLayerCapability.query)) {
      throw ArgumentError('Layer $id does not support queries.');
    }
    _replace(id, value.copyWith(queryable: queryable));
  }

  void setOpacity(String id, double opacity) {
    final value = _layer(id);
    if (!value.isGroup &&
        !value.capabilities.contains(GeoLayerCapability.opacity)) {
      throw ArgumentError('Layer $id does not support opacity.');
    }
    _replace(id, value.copyWith(opacity: opacity));
  }

  void setPolicies(String id, GeoLayerPolicies policies) =>
      _replace(id, _layer(id).copyWith(policies: policies));
  void setStatus(String id, GeoLayerStatus status) =>
      _replace(id, _layer(id).copyWith(status: status));
  void setSource(
    String id, {
    required String reference,
    required String revision,
  }) => _replace(
    id,
    _layer(id).copyWith(
      sourceReference: reference,
      sourceRevision: revision,
      status: GeoLayerStatus(lifecycle: _layer(id).status.lifecycle),
    ),
  );
  void setConfiguration(
    String id,
    Map<String, Object?> configuration, {
    required int schemaVersion,
    String? styleRevision,
  }) => _replace(
    id,
    _layer(id).copyWith(
      configuration: configuration,
      configurationVersion: schemaVersion,
      styleRevision: styleRevision,
      clearConfigurationIssue: true,
    ),
  );
  void select(Iterable<GeoFeatureId> identities) {
    _requireOpen();
    _selection.clear();
    _selection.addAll(identities);
  }

  void validate() {
    _requireOpen();
    if (_layers.length > 10000) {
      throw ArgumentError('At most 10000 layers are supported per controller.');
    }
    final byId = {for (final layer in _layers) layer.id: layer};
    for (final layer in _layers) {
      if ([layer.id, layer.owner, layer.kind].any((v) => v.trim().isEmpty) ||
          !layer.opacity.isFinite ||
          layer.opacity < 0 ||
          layer.opacity > 1 ||
          layer.configurationVersion < 1) {
        throw ArgumentError(
          'Layer ${layer.id} has invalid identity, opacity or schema version.',
        );
      }
      layer.status.coverage?.validate();
      layer.filter.validate();
      final visited = <String>{};
      var current = layer;
      var inheritedOpacity = 1.0;
      while (true) {
        if (!visited.add(current.id) || visited.length > 256) {
          throw ArgumentError(
            'Layer parent cycle or excessive depth at ${layer.id}.',
          );
        }
        inheritedOpacity *= current.opacity;
        if (current.parentId == null) break;
        final parent = byId[current.parentId];
        if (parent == null) {
          throw ArgumentError('Missing parent ${current.parentId}.');
        }
        if (!parent.isGroup) {
          throw ArgumentError('Layer ${parent.id} is not a group.');
        }
        current = parent;
      }
      if (!layer.isGroup &&
          inheritedOpacity != 1 &&
          !layer.capabilities.contains(GeoLayerCapability.opacity)) {
        throw ArgumentError(
          'Layer ${layer.id} cannot apply inherited opacity.',
        );
      }
    }
    for (final identity in _selection) {
      if (!byId.containsKey(identity.layerId) ||
          identity.featureId.trim().isEmpty) {
        throw ArgumentError('Selection references missing content.');
      }
    }
  }

  List<GeoLayer> _ordered() {
    final children = <String?, List<GeoLayer>>{};
    for (final layer in _layers) {
      (children[layer.parentId] ??= []).add(layer);
    }
    final result = <GeoLayer>[];
    void visit(String? parent) {
      for (final layer in children[parent] ?? <GeoLayer>[]) {
        result.add(layer);
        visit(layer.id);
      }
    }

    visit(null);
    return result;
  }
}
