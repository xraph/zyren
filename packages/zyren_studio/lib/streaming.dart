import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'zyren_studio.dart';

/// Readers must enforce maxBytes during transport, including redirects.
typedef ZyrenRead =
    Future<Uint8List> Function(
      Uri uri,
      int maxBytes,
      LoadCancellation cancellation,
    );
const _limit = 16 * 1024 * 1024;
String _hash(List<int> bytes) => sha256.convert(bytes).toString();
Uri _relative(String path) {
  final uri = Uri.parse(path);
  if (uri.hasScheme ||
      uri.hasAuthority ||
      uri.path.startsWith('/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.any((s) => s == '..' || s == '.' || s.contains('\\')) ||
      uri.path.isEmpty) {
    throw const FormatException('Scene references must be relative paths.');
  }
  return uri;
}

/// A .zyren manifest and immutable content-addressed companion files.
final class ZyrenScenePackage {
  final Map<String, Uint8List> files;
  final Uint8List manifest;
  ZyrenScenePackage._(this.manifest, this.files);

  /// Resolves prefab overrides once and prunes unused assets without changing
  /// geometry or material values. Animated/extended scenes stay in one chunk.
  static ZyrenScenePackage compile(
    StudioDocument source, {
    Map<String, Uint8List> resources = const {},
  }) {
    final preserveDefinitions =
        source.extensions.isNotEmpty ||
        source.encode().contains('"extensionOverrides"') ||
        source.prefabs.any((p) => p.toJson().containsKey('extensions'));
    final nodes = preserveDefinitions
        ? source.nodes
        : source.expandedNodes.values
              .map(
                (n) => n.kind == StudioNodeKind.prefab
                    ? n.copyWith(kind: StudioNodeKind.group)
                    : n,
              )
              .toList();
    final used = preserveDefinitions
        ? source.assets.map((a) => a.id).toSet()
        : source.expandedNodes.values.map((n) => n.assetId).toSet();
    final document = source.copyWith(
      nodes: nodes,
      prefabs: preserveDefinitions ? source.prefabs : const [],
      assets: source.assets.where((a) => used.contains(a.id)),
    );
    final groups = <List<StudioNode>>[];
    if (document.clips.isNotEmpty || preserveDefinitions) {
      groups.add(nodes);
    } else {
      final byId = {for (final n in nodes) n.id: n};
      final roots = <String, List<StudioNode>>{};
      for (final node in nodes) {
        var root = node;
        while (root.parentId != null) {
          root = byId[root.parentId]!;
        }
        (roots[root.id] ??= []).add(node);
      }
      groups.addAll(roots.values);
    }
    final files = <String, Uint8List>{};
    final chunks = <Map<String, Object?>>[];
    for (final group in groups) {
      final assetIds = preserveDefinitions
          ? used
          : group.map((n) => n.assetId).toSet();
      final part = document.copyWith(
        nodes: group,
        assets: document.assets.where((a) => assetIds.contains(a.id)),
      );
      final bytes = Uint8List.fromList(gzip.encode(utf8.encode(part.encode())));
      final digest = _hash(bytes), path = 'chunks/${_hash(bytes)}.zyrenchunk';
      files[path] = bytes;
      chunks.add({
        'id': group.isEmpty ? 'scene' : group.first.id,
        'uri': path,
        'sha256': digest,
        'bytes': bytes.length,
        'nodes': part.expandedNodes.keys.toList(),
      });
    }
    final resourceManifest = <String, Object?>{};
    for (final entry in resources.entries) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key) ||
          entry.value.length > 192 * 1024 * 1024) {
        throw ArgumentError('Invalid resource pin.');
      }
      final path = 'assets/${entry.key}.zyrenbundle';
      files[path] = Uint8List.fromList(entry.value);
      resourceManifest[entry.key] = {
        'uri': path,
        'sha256': _hash(entry.value),
        'bytes': entry.value.length,
      };
    }
    final metadata = jsonDecode(document.encode()) as Map<String, dynamic>;
    metadata['nodes'] = [];
    if (!preserveDefinitions) metadata['assets'] = [];
    metadata['clips'] = [];
    metadata['extensions'] = {};
    final manifest = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'zyren.scene',
          'version': 1,
          'profile': 'lossless-stream',
          'metadata': metadata,
          'chunks': chunks,
          'resources': resourceManifest,
        }),
      ),
    );
    return ZyrenScenePackage._(manifest, Map.unmodifiable(files));
  }
}

/// Loads chunks on demand into a stable native scene. Call close only after the
/// renderer releases this scene. Host plugins own interaction and animation.
final class ZyrenSceneStream {
  final Uri uri;
  final ZyrenRead read;
  final StudioAssetResolver? assets;
  final StudioExtensionRegistry? extensions;
  final Map<String, dynamic> manifest;
  final StudioDocument metadata;
  final Scene scene = Scene();
  late final PerspectiveCamera camera = metadata.camera.createCamera();
  final Map<String, StudioScene> loaded = {};
  final Map<String, StudioAssetScope> _scopes = {};
  final Map<String, Future<StudioScene>> _pending = {};
  final StudioCancellation _cancel = StudioCancellation();
  bool _closed = false;
  ZyrenSceneStream._(
    this.uri,
    this.read,
    this.assets,
    this.extensions,
    this.manifest,
    this.metadata,
  ) {
    metadata.environment.apply(scene);
  }
  List<String> get chunkIds => List.unmodifiable(
    (manifest['chunks'] as List).map((c) => c['id'] as String),
  );
  static Future<ZyrenSceneStream> open(
    Uri uri, {
    required ZyrenRead read,
    StudioAssetResolver? assets,
    StudioExtensionRegistry? extensions,
    LoadCancellation? cancellation,
  }) async {
    final token = cancellation ?? StudioCancellation();
    final bytes = await read(uri, _limit, token);
    token.throwIfCancelled();
    if (bytes.length > _limit) {
      throw const FormatException('Manifest exceeds limit.');
    }
    final root = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (root['format'] != 'zyren.scene' ||
        root['version'] != 1 ||
        root['chunks'] is! List ||
        (root['chunks'] as List).length > 1000) {
      throw const FormatException('Unsupported .zyren manifest.');
    }
    final ids = <String>{}, nodes = <String>{};
    for (final chunk in root['chunks'] as List) {
      _validateReference(chunk, _limit);
      if (!ids.add(chunk['id'] as String)) {
        throw const FormatException('Duplicate chunk ID.');
      }
      for (final id in chunk['nodes'] as List) {
        if (!nodes.add(id as String) ||
            nodes.length > StudioDocument.maxNodes) {
          throw const FormatException('Duplicate or excessive node IDs.');
        }
      }
    }
    if ((root['resources'] as Map).length > StudioDocument.maxNodes) {
      throw const FormatException('Too many resource references.');
    }
    for (final entry in (root['resources'] as Map<String, dynamic>).entries) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key)) {
        throw const FormatException('Invalid resource pin.');
      }
      _validateReference(entry.value, 192 * 1024 * 1024);
    }
    return ZyrenSceneStream._(
      uri,
      read,
      assets,
      extensions,
      root,
      StudioDocument.decode(jsonEncode(root['metadata'])),
    );
  }

  static void _validateReference(dynamic entry, int limit) {
    _relative(entry['uri'] as String);
    if (entry['bytes'] is! int ||
        entry['bytes'] < 0 ||
        entry['bytes'] > limit ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry['sha256'] as String)) {
      throw const FormatException('Invalid scene reference.');
    }
  }

  Future<Uint8List> readResource(String pin) async {
    if (_closed) throw StateError('Scene stream closed.');
    final entry = (manifest['resources'] as Map)[pin];
    if (entry == null) throw StateError('Missing resource $pin.');
    return _readReference(entry);
  }

  Future<Uint8List> _readReference(dynamic entry) async {
    _cancel.throwIfCancelled();
    final bytes = await read(
      uri.resolveUri(_relative(entry['uri'] as String)),
      entry['bytes'] as int,
      _cancel,
    );
    _cancel.throwIfCancelled();
    if (bytes.length != entry['bytes'] || _hash(bytes) != entry['sha256']) {
      throw const FormatException('Scene reference integrity mismatch.');
    }
    return bytes;
  }

  Future<StudioScene> loadChunk(String id) {
    if (_closed) throw StateError('Scene stream closed.');
    if (loaded.containsKey(id)) return Future.value(loaded[id]);
    return _pending.putIfAbsent(
      id,
      () => _load(id).whenComplete(() {
        _pending.remove(id);
      }),
    );
  }

  Future<StudioDocument> readChunkDocument(String id) async {
    final entry = (manifest['chunks'] as List)
        .where((c) => c['id'] == id)
        .firstOrNull;
    if (entry == null) throw ArgumentError.value(id, 'chunk');
    final bytes = await _readReference(entry);
    final decoded = BytesBuilder();
    await for (final part in gzip.decoder.bind(Stream.value(bytes))) {
      _cancel.throwIfCancelled();
      if (decoded.length + part.length > _limit) {
        throw const FormatException('Decoded chunk exceeds limit.');
      }
      decoded.add(part);
    }
    final document = StudioDocument.decode(utf8.decode(decoded.takeBytes()));
    if (document.id != metadata.id ||
        jsonEncode(document.environment.toJson()) !=
            jsonEncode(metadata.environment.toJson()) ||
        jsonEncode(document.camera.toJson()) !=
            jsonEncode(metadata.camera.toJson()) ||
        document.expandedNodes.keys
            .toSet()
            .difference((entry['nodes'] as List).cast<String>().toSet())
            .isNotEmpty ||
        document.expandedNodes.length != (entry['nodes'] as List).length) {
      throw const FormatException('Chunk differs from manifest.');
    }
    return document;
  }

  Future<StudioDocument> readDocument() async {
    if (_closed) throw StateError('Scene stream closed.');
    if (manifest['source'] != null) {
      final source = StudioDocument.decode(jsonEncode(manifest['source']));
      if (source.id != metadata.id) {
        throw const FormatException('Source identity differs from manifest.');
      }
      return source;
    }
    final parts = <StudioDocument>[];
    for (final id in chunkIds) {
      parts.add(await readChunkDocument(id));
    }
    return metadata.copyWith(
      nodes: parts.expand((p) => p.nodes),
      assets: {
        for (final p in parts)
          for (final a in p.assets) a.id: a,
      }.values,
      clips: parts.expand((p) => p.clips),
      extensions: {for (final p in parts) ...p.extensions},
    );
  }

  Future<StudioScene> _load(String id) async {
    final document = await readChunkDocument(id);
    (extensions ?? StudioExtensionRegistry()).validateDocument(
      document,
      requireSupported: true,
    );
    if (document.assets.isNotEmpty && assets == null) {
      throw StateError('Scene needs an asset resolver.');
    }
    final scope = assets == null
        ? StudioAssetScope()
        : await StudioAssetScope.load(document, assets!, cancellation: _cancel);
    try {
      _cancel.throwIfCancelled();
      final value = StudioScene(
        document,
        assets: scope,
        extensionRegistry: extensions,
        includeEnvironment: false,
      );
      scene.add(value.scene);
      loaded[id] = value;
      _scopes[id] = scope;
      return value;
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  Future<void> loadAll() async {
    for (final id in chunkIds) {
      await loadChunk(id);
    }
  }

  Future<void> unloadChunk(String id) async {
    final pending = _pending[id];
    if (pending != null) await pending;
    final value = loaded.remove(id);
    value?.scene.parent?.remove(value.scene);
    await _scopes.remove(id)?.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancel.cancel();
    for (final future in _pending.values.toList()) {
      try {
        await future;
      } catch (_) {}
    }
    for (final id in loaded.keys.toList()) {
      await unloadChunk(id);
    }
  }
}
