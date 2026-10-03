part of '../../training.dart';

final class DemonstrationArtifact {
  final String manifestHash, observationHash, actionHash, source, partition;
  final int steps;
  DemonstrationArtifact({
    required this.manifestHash,
    required this.observationHash,
    required this.actionHash,
    required this.source,
    required this.partition,
    required this.steps,
  }) {
    if (![manifestHash, observationHash, actionHash].every(_digest) ||
        !['player', 'scripted'].contains(source) ||
        !['train', 'validation', 'test'].contains(partition) ||
        steps < 1 ||
        steps > 10000000) {
      throw ArgumentError('Invalid demonstration pins.');
    }
  }
}
