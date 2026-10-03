part of '../../zyren_game.dart';

/// Native capabilities and immutable compiler options for one target.
final class GameBuildProfile {
  final String id;
  final int fixedHz;
  final List<String> capabilities;
  GameBuildProfile({
    required String id,
    this.fixedHz = 60,
    List<String> capabilities = const [],
  }) : id = _id(id),
       capabilities = List.unmodifiable(capabilities.map(_id)) {
    if (fixedHz < 1 || fixedHz > 240 || capabilities.length > 256) {
      throw ArgumentError('Invalid build profile.');
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'fixedHz': fixedHz,
    'capabilities': capabilities,
  };
}

/// Runtime asset pins contain no editor or Pipeline objects.
final class GameAssetReference {
  final String id, revision, digest;
  final Uri uri;
  GameAssetReference({
    required String id,
    required String revision,
    required this.uri,
    required this.digest,
  }) : id = _id(id),
       revision = _id(revision) {
    if (!uri.hasScheme ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw ArgumentError('Invalid game asset pin.');
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'revision': revision,
    'uri': uri.toString(),
    'sha256': digest,
  };
  factory GameAssetReference.fromJson(Map<String, Object?> json) =>
      GameAssetReference(
        id: _string(json['id']),
        revision: _string(json['revision']),
        uri: Uri.parse(_string(json['uri'])),
        digest: _string(json['sha256']),
      );
}
