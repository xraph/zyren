part of '../../zyren_game_ai.dart';

enum BeliefSource { visible, audible, team, authored }

enum BeliefKnowledge { observed, unobserved, unknown, expired }

final class Belief {
  final String key;
  final GameEntityHandle? target;
  final Vec3? position;
  final GameEntityHandle positionFrame;
  final int observedTick, ttlTicks;
  final BeliefSource source;
  final double confidence;
  final HeardSound? sound;
  const Belief._({
    required this.key,
    required this.target,
    required this.position,
    required this.positionFrame,
    required this.observedTick,
    required this.ttlTicks,
    required this.source,
    required this.confidence,
    this.sound,
  });
}

final class AgedBelief {
  final Belief belief;
  final int ageTicks;
  final double confidence;
  final BeliefKnowledge knowledge;
  const AgedBelief._(
    this.belief,
    this.ageTicks,
    this.confidence,
    this.knowledge,
  );
  String get key => belief.key;
  GameEntityHandle? get target => belief.target;
  Vec3? get position => belief.position;
  GameEntityHandle get positionFrame => belief.positionFrame;
  int get observedTick => belief.observedTick;
  int get ttlTicks => belief.ttlTicks;
  BeliefSource get source => belief.source;
  HeardSound? get sound => belief.sound;
}

final class TeamMemoryPolicy {
  final String teamId;
  final int delayTicks;
  final double range;
  TeamMemoryPolicy({
    required this.teamId,
    this.delayTicks = 1,
    this.range = 20,
  }) {
    _name(teamId);
    _bounded(delayTicks, 36000, 'delayTicks', zero: true);
    if (!range.isFinite || range <= 0 || range > 100000) {
      throw ArgumentError('Invalid team range.');
    }
  }
}

/// Explicit game communication. Position retains the sender's capture frame.
final class TeamBeliefMessage {
  final String teamId;
  final BrainIdentity sender, recipient;
  final GameEntityHandle target;
  final Vec3 position;
  final int observedTick, sentTick, ttlTicks;
  final double confidence;
  TeamBeliefMessage({
    required this.teamId,
    required this.sender,
    required this.recipient,
    required this.target,
    required this.position,
    required this.observedTick,
    required this.sentTick,
    required this.ttlTicks,
    required this.confidence,
  }) {
    _name(teamId);
    if (!position.isFinite ||
        observedTick < 0 ||
        sentTick < observedTick ||
        ttlTicks < 1 ||
        ttlTicks > 36000 ||
        !confidence.isFinite ||
        confidence < 0 ||
        confidence > 1) {
      throw ArgumentError('Invalid team belief message.');
    }
  }
}
