part of '../../zyren_game.dart';

/// Validated runtime data. Hosts resolve the pinned assets before activation.
final class CompiledGameProject {
  final GameProject project;
  final int fixedHz;
  final Map<String, int> componentVersions, systemVersions;
  final Map<String, String> artifactHashes;
  String get id => project.id;
  List<GameLevel> get levels => project.levels;
  List<String> get capabilityRequirements => project.capabilityRequirements;
  CompiledGameProject({
    required this.project,
    this.fixedHz = 60,
    Map<String, int> systemVersions = const {},
    Map<String, String> artifactHashes = const {},
  }) : componentVersions = Map.unmodifiable({
         for (final entry in project.registry._codecs.entries)
           entry.key: entry.value.version,
       }),
       systemVersions = Map.unmodifiable(systemVersions),
       artifactHashes = Map.unmodifiable(artifactHashes) {
    project.requireActivation();
    if (fixedHz < 1 || fixedHz > 240) {
      throw RangeError.range(fixedHz, 1, 240, 'fixedHz');
    }
    if (systemVersions.length > 256 || artifactHashes.length > 4096) {
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
  }
}
