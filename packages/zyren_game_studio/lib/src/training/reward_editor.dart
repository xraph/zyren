part of '../../training.dart';

final class TrainingRewards {
  final Map<String, double> weights;
  TrainingRewards(Map<String, double> weights)
    : weights = Map.unmodifiable(weights) {
    if (weights.isEmpty ||
        weights.length > 64 ||
        weights.entries.any(
          (v) =>
              !RegExp(r'^[a-zA-Z0-9_.-]{1,128}$').hasMatch(v.key) ||
              !v.value.isFinite ||
              v.value.abs() > 100,
        )) {
      throw ArgumentError('Reward weights exceed bounds.');
    }
  }
  TrainingScenarioDocument apply(TrainingScenarioDocument document) {
    final next = document.data;
    next['rewards'] = weights;
    return TrainingScenarioDocument(next);
  }
}
