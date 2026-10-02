import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'zyren_studio.dart';

enum StudioCommandKind { select, transform, undo, redo }

enum StudioCommandFailure { unavailable, denied, stale, invalid, capacity }

final class StudioCommandException implements Exception {
  final StudioCommandFailure code;
  final String message;
  const StudioCommandException(this.code, this.message);
  @override
  String toString() => '${code.name}: $message';
}

/// A bounded command adapter for a host's shared agent provider.
/// It neither grants permissions nor starts a transport.
final class StudioCommands {
  final StudioScene scene;
  final String sessionId;
  final bool Function(StudioCommandKind) isAllowed;
  final bool Function() isAvailable;
  final int receiptLimit;
  final _receipts = <String, (String, Map<String, Object?>)>{};
  int _revision = 0;
  bool _closed = false;
  StudioCommands({
    required this.scene,
    required this.sessionId,
    required this.isAllowed,
    required this.isAvailable,
    this.receiptLimit = 256,
  }) {
    if (receiptLimit < 1 || sessionId.isEmpty) {
      throw ArgumentError('Invalid command session.');
    }
  }

  int get sequence => _revision;

  String get revision => '$sessionId:${scene.revision}:$_revision';

  Map<String, Object?> inspect() => {
    'documentId': scene.document.id,
    'sessionId': sessionId,
    'revision': revision,
    'sceneRevision': scene.scene.revision,
    'selectedId': scene.idFor(scene.tools.selected),
    'canUndo': scene.tools.canUndo,
    'canRedo': scene.tools.canRedo,
    'available': !_closed && isAvailable(),
    'allowedActions': [
      for (final kind in StudioCommandKind.values)
        if (!_closed && isAllowed(kind)) kind.name,
    ],
    'receiptCount': _receipts.length,
    'receiptLimit': receiptLimit,
  };

  Map<String, Object?> execute({
    required String commandId,
    required String expectedRevision,
    required StudioCommandKind kind,
    String? targetId,
    Vec3? position,
    Quat? rotation,
    Vec3? scale,
  }) {
    if (_closed || !isAvailable()) {
      throw const StudioCommandException(
        StudioCommandFailure.unavailable,
        'Editor is unavailable.',
      );
    }
    if (!isAllowed(kind)) {
      throw const StudioCommandException(
        StudioCommandFailure.denied,
        'Host has not granted this action.',
      );
    }
    if (commandId.trim().isEmpty || commandId.length > 256) {
      throw const StudioCommandException(
        StudioCommandFailure.invalid,
        'Invalid command ID.',
      );
    }
    final signature = jsonEncode([
      expectedRevision,
      kind.name,
      targetId,
      position?.storage,
      rotation == null
          ? null
          : [rotation.x, rotation.y, rotation.z, rotation.w],
      scale?.storage,
    ]);
    final prior = _receipts[commandId];
    if (prior != null) {
      if (prior.$1 != signature) {
        throw const StudioCommandException(
          StudioCommandFailure.invalid,
          'Command ID was reused with different input.',
        );
      }
      return prior.$2;
    }
    if (expectedRevision != revision) {
      throw const StudioCommandException(
        StudioCommandFailure.stale,
        'Refresh the editor state before editing.',
      );
    }
    if (_receipts.length >= receiptLimit) {
      throw const StudioCommandException(
        StudioCommandFailure.capacity,
        'Start a new command session before sending more edits.',
      );
    }
    if ((kind == StudioCommandKind.undo || kind == StudioCommandKind.redo) &&
            targetId != null ||
        kind != StudioCommandKind.transform &&
            (position != null || rotation != null || scale != null)) {
      throw const StudioCommandException(
        StudioCommandFailure.invalid,
        'Unexpected command fields.',
      );
    }
    final target = scene.objects[targetId];
    if (targetId != null && (target == null || !_member(target))) {
      throw const StudioCommandException(
        StudioCommandFailure.stale,
        'Target no longer belongs to this scene.',
      );
    }
    final before = {
      for (final entry in scene.objects.entries)
        entry.key: entry.value.localMatrix,
    };
    final previousSelection = scene.idFor(scene.tools.selected);
    switch (kind) {
      case StudioCommandKind.select:
        scene.tools.select(target);
      case StudioCommandKind.transform:
        if (target == null ||
            position == null && rotation == null && scale == null) {
          throw const StudioCommandException(
            StudioCommandFailure.invalid,
            'Transform requires a target and at least one component.',
          );
        }
        scene.tools.transform(
          target,
          position: position,
          rotation: rotation,
          scale: scale,
        );
      case StudioCommandKind.undo:
        if (!scene.tools.undo()) {
          throw const StudioCommandException(
            StudioCommandFailure.unavailable,
            'No edit to undo.',
          );
        }
      case StudioCommandKind.redo:
        if (!scene.tools.redo()) {
          throw const StudioCommandException(
            StudioCommandFailure.unavailable,
            'No edit to redo.',
          );
        }
    }
    _revision++;
    final result = Map<String, Object?>.unmodifiable({
      ...inspect(),
      'commandId': commandId,
      'affectedIds': kind == StudioCommandKind.select
          ? <String>{?previousSelection, ?targetId}.toList()
          : [
              for (final entry in scene.objects.entries)
                if (before[entry.key] != entry.value.localMatrix) entry.key,
            ],
    });
    _receipts[commandId] = (signature, result);
    return result;
  }

  bool _member(Object3D object) {
    for (
      Object3D? current = object.parent;
      current != null;
      current = current.parent
    ) {
      if (identical(current, scene.content)) {
        return scene.content.parent == scene.scene;
      }
      if (!scene.objects.containsValue(current)) return false;
    }
    return false;
  }

  void dispose() {
    _closed = true;
    _receipts.clear();
  }
}
