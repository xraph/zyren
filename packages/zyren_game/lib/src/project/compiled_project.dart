part of '../../zyren_game.dart';

/// Validated runtime data. Hosts resolve the pinned assets before activation.
final class CompiledGameProject {
  final GameProject project;
  final int fixedHz;
  final Map<String, int> componentVersions, systemVersions;
  final Map<String, String> artifactHashes;
  final List<GameAssetReference> assets;
  final Map<String, List<Map<String, Object?>>> sceneNodes;
  final String compilerVersion;
  late final String buildId;
  String get id => project.id;
  List<GameLevel> get levels => project.levels;
  List<String> get capabilityRequirements => project.capabilityRequirements;
  CompiledGameProject({
    required this.project,
    this.fixedHz = 60,
    Map<String, int> systemVersions = const {},
    Map<String, String> artifactHashes = const {},
    List<GameAssetReference> assets = const [],
    Map<String, List<Map<String, Object?>>> sceneNodes = const {},
    this.compilerVersion = '1',
  }) : componentVersions = Map.unmodifiable({
         for (final entry in project.registry._codecs.entries)
           entry.key: entry.value.version,
       }),
       systemVersions = Map.unmodifiable(systemVersions),
       artifactHashes = Map.unmodifiable(artifactHashes),
       assets = List.unmodifiable(assets),
       sceneNodes = Map.unmodifiable(
         sceneNodes.map(
           (k, v) => MapEntry(
             k,
             List<Map<String, Object?>>.unmodifiable(v.map(_json)),
           ),
         ),
       ) {
    project.requireActivation();
    if (fixedHz < 1 || fixedHz > 240) {
      throw RangeError.range(fixedHz, 1, 240, 'fixedHz');
    }
    if (systemVersions.length > 256 ||
        artifactHashes.length > 4096 ||
        assets.length > 4096 ||
        sceneNodes.length > project.levels.length) {
      throw ArgumentError('Recipe metadata limit exceeded.');
    }
    for (final entry in systemVersions.entries) {
      _id(entry.key);
      if (entry.value < 1) throw ArgumentError('Invalid system version.');
    }
    for (final entry in artifactHashes.entries) {
      _id(entry.key);
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value)) {
        throw ArgumentError('Expected SHA-256 artifact hash.');
      }
    }
    _id(compilerVersion);
    if (assets.map((a) => a.id).toSet().length != assets.length ||
        assets.any((a) => artifactHashes[a.id] != a.digest)) {
      throw ArgumentError('Asset pins differ from recipe hashes.');
    }
    for (final entry in this.sceneNodes.entries) {
      if (!project.levels.any((l) => l.id == entry.key) ||
          entry.value.length > 10000) {
        throw ArgumentError('Invalid compiled scene.');
      }
    }
    buildId = sha256
        .convert(utf8.encode(jsonEncode(_canonicalGameJson(_payload()))))
        .toString();
  }

  Map<String, Object?> _payload() => {
    'schemaVersion': 1,
    'compilerVersion': compilerVersion,
    'project': project.toJson(),
    'fixedHz': fixedHz,
    'componentVersions': componentVersions,
    'systemVersions': systemVersions,
    'artifactHashes': artifactHashes,
    'assets': assets.map((a) => a.toJson()).toList(),
    'sceneNodes': sceneNodes,
  };
  String encode() {
    final source = jsonEncode({..._payload(), 'buildId': buildId});
    _checkSource(source);
    return source;
  }

  factory CompiledGameProject.decode(String source, GameRegistry registry) {
    _checkSource(source);
    final json = _map(jsonDecode(source));
    if (json['schemaVersion'] != 1) {
      throw FormatException('Unsupported compiled game schema.');
    }
    final project = CompiledGameProject(
      project: GameProject.decode(jsonEncode(json['project']), registry),
      fixedHz: _integer(json['fixedHz']),
      compilerVersion: _string(json['compilerVersion']),
      systemVersions: _map(
        json['systemVersions'],
      ).map((k, v) => MapEntry(k, _integer(v))),
      artifactHashes: _map(
        json['artifactHashes'],
      ).map((k, v) => MapEntry(k, _string(v))),
      assets: _list(
        json['assets'],
      ).map((a) => GameAssetReference.fromJson(_map(a))).toList(),
      sceneNodes: _map(
        json['sceneNodes'],
      ).map((k, v) => MapEntry(k, _list(v).map(_map).toList())),
    );
    if (project.buildId != json['buildId'] ||
        jsonEncode(_canonicalGameJson(project.componentVersions)) !=
            jsonEncode(_canonicalGameJson(json['componentVersions']))) {
      throw StateError('Compiled project pins differ.');
    }
    return project;
  }
}

Object? _canonicalGameJson(Object? value) => value is Map
    ? {
        for (final key in value.keys.cast<String>().toList()..sort())
          key: _canonicalGameJson(value[key]),
      }
    : value is List
    ? value.map(_canonicalGameJson).toList()
    : value;
