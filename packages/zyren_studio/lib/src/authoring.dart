part of '../zyren_studio.dart';

/// Immutable edits validate the complete next document before touching a scene.
abstract final class StudioAuthoring {
  static StudioDocument updateExtension(
    StudioDocument document,
    StudioExtensionRecord record, {
    StudioExtensionRegistry? registry,
  }) {
    final next = document.copyWith(
      extensions: {...document.extensions, record.namespace: record},
    );
    (registry ?? StudioExtensionRegistry()).validateDocument(next);
    return next;
  }

  static StudioDocument addBox(
    StudioDocument document, {
    required String id,
    String label = 'Box',
  }) => document.copyWith(
    nodes: [
      ...document.nodes,
      StudioNode(id: id, label: label),
    ],
  );

  static StudioDocument updateNode(
    StudioDocument document,
    String id,
    StudioOverride value,
  ) {
    if (!document.expandedNodes.containsKey(id)) {
      throw ArgumentError('Unknown node.');
    }
    final owner = document.prefabOwners[id];
    return document.copyWith(
      nodes: document.nodes.map((node) {
        if (owner == null) return node.id == id ? value.apply(node) : node;
        if (node.id != owner) return node;
        final path = id.substring(owner.length + 1);
        final effective = value.apply(document.expandedNodes[id]!);
        return node.copyWith(
          overrides: {
            ...node.overrides,
            path: StudioOverride(
              position: effective.position,
              scale: effective.scale,
              rotation: effective.rotation,
              visible: effective.visible,
              material: effective.material,
            ),
          },
        );
      }),
    );
  }

  static StudioDocument remove(
    StudioDocument document,
    String id, {
    StudioExtensionRegistry? registry,
  }) {
    if (!document.expandedNodes.containsKey(id)) {
      throw ArgumentError('Unknown node.');
    }
    if (document.prefabOwners.containsKey(id)) {
      throw ArgumentError('Remove the prefab instance or edit its definition.');
    }
    final removed = <String>{id};
    bool changed;
    do {
      changed = false;
      for (final node in document.expandedNodes.values) {
        if (removed.contains(node.parentId) && removed.add(node.id)) {
          changed = true;
        }
      }
    } while (changed);
    final clips = <StudioClip>[];
    for (final clip in document.clips) {
      final tracks = {...clip.tracks}
        ..removeWhere((key, _) => removed.contains(key));
      if (tracks.isNotEmpty) {
        clips.add(
          StudioClip(
            id: clip.id,
            label: clip.label,
            durationMicroseconds: clip.durationMicroseconds,
            tracks: tracks,
          ),
        );
      }
    }
    final next = document.copyWith(
      nodes: document.nodes.where((n) => !removed.contains(n.id)),
      clips: clips,
    );
    (registry ?? StudioExtensionRegistry()).validateEdit(document, next);
    return next;
  }

  static StudioDocument createPrefab(
    StudioDocument document,
    String id, {
    required String prefabId,
    StudioExtensionRegistry? registry,
  }) {
    if (document.prefabOwners.containsKey(id)) {
      throw ArgumentError('Select an authored instance.');
    }
    final root = document.nodes.singleWhere((n) => n.id == id);
    final selected = <String>{id};
    bool changed;
    do {
      changed = false;
      for (final node in document.nodes) {
        if (selected.contains(node.parentId) && selected.add(node.id)) {
          changed = true;
        }
      }
    } while (changed);
    // Existing animation targets must be deliberately retargeted, never silently dropped.
    if (document.clips.any(
      (c) => c.tracks.keys.any(
        (key) => selected.any((n) => key == n || key.startsWith('$n/')),
      ),
    )) {
      throw StateError(
        'Remove or retarget animation tracks before converting these nodes to a prefab.',
      );
    }
    final definitions = document.nodes
        .where((n) => selected.contains(n.id))
        .map(
          (n) => n.id == id
              ? n.copyWith(
                  clearParent: true,
                  position: Vec3.zero,
                  rotation: Quat.identity,
                  scale: Vec3.one,
                )
              : n,
        )
        .toList();
    final instance = StudioNode(
      id: root.id,
      label: root.label,
      kind: StudioNodeKind.prefab,
      prefabId: prefabId,
      parentId: root.parentId,
      position: root.position,
      rotation: root.rotation,
      scale: root.scale,
    );
    final next = document.copyWith(
      nodes: [
        for (final node in document.nodes)
          if (node.id == id)
            instance
          else if (!selected.contains(node.id))
            node,
      ],
      prefabs: [
        ...document.prefabs,
        StudioPrefab(
          id: prefabId,
          label: root.label,
          version: '1',
          nodes: definitions,
        ),
      ],
    );
    final remapping = {
      for (final node in document.expandedNodes.values)
        if (selected.contains(node.id) ||
            selected.any((id) => node.id.startsWith('$id/')))
          node.id: '$id/${node.id}',
    };
    return (registry ?? StudioExtensionRegistry()).remapDocument(
      document,
      next,
      remapping,
    );
  }

  static StudioDocument instancePrefab(
    StudioDocument document,
    String prefabId, {
    required String id,
  }) => document.copyWith(
    nodes: [
      ...document.nodes,
      StudioNode(
        id: id,
        label: document.prefabs.singleWhere((p) => p.id == prefabId).label,
        kind: StudioNodeKind.prefab,
        prefabId: prefabId,
        position: const Vec3(2, 0, 0),
      ),
    ],
  );

  static StudioDocument putKeyframe(
    StudioDocument document, {
    required String clipId,
    required String nodeId,
    required StudioKeyframe frame,
    required int durationMicroseconds,
  }) {
    if (!document.expandedNodes.containsKey(nodeId)) {
      throw ArgumentError('Unknown animation target.');
    }
    final prior = document.clips.where((c) => c.id == clipId).firstOrNull;
    final frames = [...?prior?.tracks[nodeId]]
      ..removeWhere((f) => f.microseconds == frame.microseconds);
    frames.add(frame);
    frames.sort((a, b) => a.microseconds.compareTo(b.microseconds));
    final clip = StudioClip(
      id: clipId,
      label: prior?.label ?? clipId,
      durationMicroseconds: durationMicroseconds,
      tracks: {...?prior?.tracks, nodeId: frames},
    );
    return document.copyWith(
      clips: [...document.clips.where((c) => c.id != clipId), clip],
    );
  }

  /// Retime or remove an exact key. Validation leaves the input untouched.
  static StudioDocument editKeyframe(
    StudioDocument document, {
    required String clipId,
    required String nodeId,
    required int microseconds,
    int? moveToMicroseconds,
  }) {
    final clip = document.clips.singleWhere((c) => c.id == clipId);
    final frames = clip.tracks[nodeId];
    if (frames == null) throw ArgumentError('Unknown animation track.');
    final frame = frames.singleWhere((f) => f.microseconds == microseconds);
    if (moveToMicroseconds != microseconds &&
        frames.any((f) => f.microseconds == moveToMicroseconds)) {
      throw ArgumentError('A key already occupies that time.');
    }
    final edited = frames.where((f) => f != frame).toList();
    if (moveToMicroseconds != null) {
      edited.add(
        StudioKeyframe(
          microseconds: moveToMicroseconds,
          position: frame.position,
          scale: frame.scale,
          rotation: frame.rotation,
          visible: frame.visible,
        ),
      );
    }
    edited.sort((a, b) => a.microseconds.compareTo(b.microseconds));
    final tracks = {...clip.tracks}..remove(nodeId);
    if (edited.isNotEmpty) tracks[nodeId] = edited;
    return document.copyWith(
      clips: [
        for (final c in document.clips)
          if (c.id != clipId)
            c
          else if (tracks.isNotEmpty)
            StudioClip(
              id: c.id,
              label: c.label,
              durationMicroseconds: c.durationMicroseconds,
              tracks: tracks,
            ),
      ],
    );
  }

  static StudioDocument resizeClip(
    StudioDocument document,
    String clipId,
    int microseconds,
  ) => document.copyWith(
    clips: [
      for (final clip in document.clips)
        if (clip.id != clipId)
          clip
        else
          StudioClip(
            id: clip.id,
            label: clip.label,
            durationMicroseconds: microseconds,
            tracks: clip.tracks,
          ),
    ],
  );
}
