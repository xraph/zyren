part of '../../zyren_game_ai.dart';

/// Host-owned membership for one episode. Membership changes invalidate messages.
final class GameTeam {
  final String id, episodeId;
  final GameEntityTable entities;
  final int maxMembers, maxMembershipChanges;
  final _members = <GameEntityHandle, BrainIdentity>{};
  final _epochs = <GameEntityHandle, int>{};
  int _revision = 0;
  GameTeam({
    required this.id,
    required this.episodeId,
    required this.entities,
    this.maxMembers = 64,
    this.maxMembershipChanges = 4096,
  }) {
    _name(id);
    _name(episodeId);
    _bounded(maxMembers, 64, 'team members');
    _bounded(maxMembershipChanges, 4096, 'membership changes');
  }
  int get revision => _revision;
  List<BrainIdentity> get members => List.unmodifiable(
    _members.values.where((m) => entities.isAlive(m.entity)),
  );
  bool contains(GameEntityHandle actor) =>
      _members.containsKey(actor) && entities.isAlive(actor);
  BrainIdentity? identityFor(GameEntityHandle actor) =>
      contains(actor) ? _members[actor] : null;
  int membershipEpoch(GameEntityHandle actor) => _epochs[actor] ?? 0;
  void _change(GameEntityHandle actor) {
    if (_revision >= maxMembershipChanges) {
      throw StateError(
        'Team membership change budget exhausted. Start a new episode.',
      );
    }
    _epochs[actor] = ++_revision;
  }

  void join(BrainIdentity identity) {
    if (identity.episodeId != episodeId || !entities.isAlive(identity.entity)) {
      throw ArgumentError('Foreign episode or dead team member.');
    }
    if (_members[identity.entity] == identity) return;
    if (!_members.containsKey(identity.entity) && _members.length >= maxMembers) {
      throw StateError('Team member limit exceeded.');
    }
    _change(identity.entity);
    _members[identity.entity] = identity;
  }

  void leave(GameEntityHandle actor) {
    if (!_members.containsKey(actor)) return;
    _change(actor);
    _members.remove(actor);
  }
}
