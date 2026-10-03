part of '../../export.dart';

final class UnsupportedGameCollaboration implements Exception {
  const UnsupportedGameCollaboration();
  @override
  String toString() =>
      'Leave the shared session to edit game components or scene structure. Transform and visibility edits use the shared authority.';
}

/// Keeps the existing room, offline queue, presence and conditional history.
/// Component and structural operations are explicitly unsupported by schema 1.
final class GameCollaborationAdapter {
  final SceneCollaborationClient? Function() connectedClient;
  GameCollaborationAdapter({required this.connectedClient});
  bool get isConnected => connectedClient()?.isClosed == false;
  String? get limitation =>
      isConnected ? const UnsupportedGameCollaboration().toString() : null;
  void guardDocument(StudioDocument current, StudioDocument next) {
    final client = connectedClient();
    if (client == null || client.isClosed) return;
    if (current.id != client.sceneId ||
        next.id != current.id ||
        _structure(current) != _structure(next)) {
      throw const UnsupportedGameCollaboration();
    }
  }

  String _structure(StudioDocument document) {
    Map<String, Object?> transformOnly(Map<String, Object?> value) => {
      for (final entry in value.entries)
        if (!{'position', 'rotation', 'scale', 'visible'}.contains(entry.key))
          entry.key: entry.value,
    };
    final structural = Map<String, Object?>.from(
      jsonDecode(document.encode()) as Map,
    );
    structural.remove('camera');
    structural['nodes'] = [
      for (final node in document.nodes)
        transformOnly(node.toJson())
          ..['overrides'] = {
            for (final entry in node.overrides.entries)
              if (transformOnly(entry.value.toJson()).isNotEmpty)
                entry.key: transformOnly(entry.value.toJson()),
          },
    ];
    return _jsonCanonical(structural);
  }
}

String _jsonCanonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_jsonCanonical(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_jsonCanonical).join(',')}]';
  return jsonEncode(value);
}
