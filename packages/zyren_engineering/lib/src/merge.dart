part of '../zyren_engineering.dart';

enum EngineeringRecordKind { object, annotation }

enum EngineeringConflictChoice { base, local, remote }

/// An explicit decision for the exact conflict values the host presented.
final class EngineeringConflictResolution {
  final EngineeringConflict conflict;
  final EngineeringConflictChoice choice;
  const EngineeringConflictResolution(this.conflict, this.choice);
}

/// JSON values are null for deleted or absent records.
final class EngineeringConflict {
  final EngineeringRecordKind kind;
  final String id;
  final String? base, local, remote;
  const EngineeringConflict(
    this.kind,
    this.id,
    this.base,
    this.local,
    this.remote,
  );
}

final class EngineeringMerge {
  final EngineeringDocument? document;
  final List<EngineeringConflict> conflicts;
  EngineeringMerge._(this.document, List<EngineeringConflict> conflicts)
    : conflicts = List.unmodifiable(conflicts);

  /// Whole-record merge. Concurrent unequal changes require explicit resolution.
  factory EngineeringMerge({
    required EngineeringDocument base,
    required EngineeringDocument local,
    required EngineeringDocument remote,
    List<EngineeringConflictResolution> resolutions = const [],
  }) {
    if (base.id != local.id || base.id != remote.id) {
      throw ArgumentError('Merge requires the same review document.');
    }
    final conflicts = <EngineeringConflict>[];
    final decisions =
        <(EngineeringRecordKind, String), EngineeringConflictResolution>{};
    for (final resolution in resolutions) {
      final key = (resolution.conflict.kind, resolution.conflict.id);
      if (decisions.containsKey(key)) {
        throw ArgumentError('Duplicate conflict resolution.');
      }
      decisions[key] = resolution;
    }
    EngineeringConflictChoice? choiceFor(EngineeringConflict conflict) {
      final resolution = decisions[(conflict.kind, conflict.id)];
      final prior = resolution?.conflict;
      return prior != null &&
              prior.base == conflict.base &&
              prior.local == conflict.local &&
              prior.remote == conflict.remote
          ? resolution!.choice
          : null;
    }

    Map<String, T> merge<T>(
      Map<String, T> before,
      Map<String, T> ours,
      Map<String, T> theirs,
      EngineeringRecordKind kind,
      Map<String, Object?> Function(T) json,
    ) {
      String? encode(T? value) =>
          value == null ? null : _canonical(json(value));
      final result = <String, T>{};
      for (final id in {...before.keys, ...ours.keys, ...theirs.keys}) {
        final b = encode(before[id]),
            l = encode(ours[id]),
            r = encode(theirs[id]);
        T? chosen;
        if (l == r || r == b) {
          chosen = ours[id];
        } else if (l == b) {
          chosen = theirs[id];
        } else {
          final conflict = EngineeringConflict(kind, id, b, l, r);
          final choice = choiceFor(conflict);
          if (choice == null) {
            conflicts.add(conflict);
            continue;
          }
          chosen = switch (choice) {
            EngineeringConflictChoice.base => before[id],
            EngineeringConflictChoice.local => ours[id],
            EngineeringConflictChoice.remote => theirs[id],
          };
        }
        if (chosen != null) result[id] = chosen;
      }
      return result;
    }

    final objects = merge(
      base.objects,
      local.objects,
      remote.objects,
      EngineeringRecordKind.object,
      (value) => value._json(),
    );
    final notes = merge(
      base.annotations,
      local.annotations,
      remote.annotations,
      EngineeringRecordKind.annotation,
      (value) => value._json(),
    );
    final unresolvedObjects = {
      for (final conflict in conflicts)
        if (conflict.kind == EngineeringRecordKind.object) conflict.id,
    };
    for (final note in notes.values) {
      if (!objects.containsKey(note.objectId) &&
          !unresolvedObjects.contains(note.objectId)) {
        final conflict = EngineeringConflict(
          EngineeringRecordKind.object,
          note.objectId,
          base.objects[note.objectId] == null
              ? null
              : _canonical(base.objects[note.objectId]!._json()),
          local.objects[note.objectId] == null
              ? null
              : _canonical(local.objects[note.objectId]!._json()),
          remote.objects[note.objectId] == null
              ? null
              : _canonical(remote.objects[note.objectId]!._json()),
        );
        final choice = choiceFor(conflict);
        final restored = switch (choice) {
          EngineeringConflictChoice.base => base.objects[note.objectId],
          EngineeringConflictChoice.local => local.objects[note.objectId],
          EngineeringConflictChoice.remote => remote.objects[note.objectId],
          null => null,
        };
        if (restored == null) {
          conflicts.add(conflict);
          unresolvedObjects.add(note.objectId);
        } else {
          objects[note.objectId] = restored;
        }
      }
    }
    if (conflicts.isNotEmpty) return EngineeringMerge._(null, conflicts);
    final document = EngineeringDocument(
      id: base.id,
      objects: objects.values,
      annotations: notes.values,
    );
    document.encode();
    return EngineeringMerge._(document, conflicts);
  }
}

String _documentSignature(EngineeringDocument document) => _canonical({
  'id': document.id,
  'objects': {
    for (final entry in document.objects.entries)
      entry.key: entry.value._json(),
  },
  'annotations': {
    for (final entry in document.annotations.entries)
      entry.key: entry.value._json(),
  },
});

String _canonical(Object? value) {
  Object? sorted(Object? value) {
    if (value is Map<String, Object?>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: sorted(value[key])};
    }
    if (value is List) return value.map(sorted).toList();
    return value;
  }

  return jsonEncode(sorted(value));
}

/// Revision tokens belong to the service and must change after every write.
final class EngineeringRevision {
  final String version;
  final EngineeringDocument document;
  EngineeringRevision({required this.version, required this.document}) {
    _text(version, 'Review version', 256);
    document.encode();
  }
}

/// The host owns transport, authentication and document access checks.
/// A failed version comparison must throw without modifying stored data.
abstract interface class EngineeringSessionStore {
  Future<EngineeringRevision> read();
  Future<EngineeringRevision> compareAndWrite({
    required String expectedVersion,
    required EngineeringDocument document,
  });
}

final class EngineeringSyncResult {
  final EngineeringRevision revision;
  final List<EngineeringConflict> conflicts;
  final bool written;
  EngineeringSyncResult._(this.revision, this.conflicts, this.written);
}
