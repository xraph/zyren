/// Native task results are separate from shaped rewards and actor observations.
final class MultiTaskOutcome {
  final bool ended, legal;
  final Map<String, String> results;
  MultiTaskOutcome._(this.ended, this.legal, Map<String, String> results)
    : results = Map.unmodifiable(results);

  factory MultiTaskOutcome.competitive({
    required bool captured,
    required bool timedOut,
    required bool legal,
    String pursuer = 'a',
    String evader = 'b',
  }) {
    if (pursuer.isEmpty || evader.isEmpty || pursuer == evader) {
      throw ArgumentError('Competitive roles must have distinct actors.');
    }
    if (!legal) {
      return MultiTaskOutcome._(true, false, {pursuer: 'draw', evader: 'draw'});
    }
    if (captured) {
      return MultiTaskOutcome._(true, true, {pursuer: 'win', evader: 'loss'});
    }
    if (timedOut) {
      return MultiTaskOutcome._(true, true, {pursuer: 'loss', evader: 'win'});
    }
    return MultiTaskOutcome._(false, true, {
      pursuer: 'pending',
      evader: 'pending',
    });
  }

  factory MultiTaskOutcome.cooperative({
    required List<String> actors,
    required Set<String> reached,
    required bool timedOut,
    required bool legal,
  }) {
    if (actors.isEmpty ||
        actors.length > 64 ||
        actors.toSet().length != actors.length ||
        actors.any((actor) => actor.isEmpty)) {
      throw ArgumentError(
        'Cooperative participants must be bounded and unique.',
      );
    }
    final complete = legal && reached.containsAll(actors),
        ended = !legal || complete || timedOut,
        result = !legal
            ? 'draw'
            : complete
            ? 'win'
            : timedOut
            ? 'loss'
            : 'pending';
    return MultiTaskOutcome._(ended, legal, {
      for (final actor in actors) actor: result,
    });
  }
}
