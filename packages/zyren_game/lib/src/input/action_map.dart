part of '../../zyren_game.dart';

final class GameActionDefinition {
  final String id;
  final bool button;
  final double deadZone;
  GameActionDefinition(String id, {this.button = false, this.deadZone = 0})
    : id = _id(id) {
    if (!deadZone.isFinite || deadZone < 0 || deadZone >= 1) {
      throw ArgumentError('Dead zone must be in [0, 1).');
    }
  }
}

final class GameInputBinding {
  final String control, action;
  final double scale;
  GameInputBinding(String control, String action, {this.scale = 1})
    : control = _id(control),
      action = _id(action) {
    if (!scale.isFinite || scale.abs() > 1 || scale == 0) {
      throw ArgumentError('Binding scale must be nonzero and within [-1, 1].');
    }
  }
}

final class GameInputMap {
  final Map<String, GameActionDefinition> actions;
  final List<GameInputBinding> bindings;
  GameInputMap({
    required List<GameActionDefinition> actions,
    required List<GameInputBinding> bindings,
  }) : actions = Map.unmodifiable({
         for (final action in actions) action.id: action,
       }),
       bindings = List.unmodifiable(bindings) {
    if (actions.isEmpty ||
        actions.length > 128 ||
        this.actions.length != actions.length ||
        bindings.length > 512) {
      throw ArgumentError('Invalid or duplicate action definitions.');
    }
    final controls = <String>{};
    for (final binding in bindings) {
      if (!controls.add(binding.control) ||
          !this.actions.containsKey(binding.action)) {
        throw ArgumentError('Duplicate control or unknown action.');
      }
    }
  }
  GameInputMap rebind(String oldControl, GameInputBinding replacement) {
    if (!bindings.any((b) => b.control == oldControl)) {
      throw ArgumentError('Unknown control.');
    }
    return GameInputMap(
      actions: actions.values.toList(),
      bindings: [
        for (final binding in bindings)
          if (binding.control == oldControl) replacement else binding,
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'actions': [
      for (final a in actions.values)
        {'id': a.id, 'button': a.button, 'deadZone': a.deadZone},
    ],
    'bindings': [
      for (final b in bindings)
        {'control': b.control, 'action': b.action, 'scale': b.scale},
    ],
  };
  factory GameInputMap.fromJson(Map<String, Object?> data) {
    if (data['version'] != 1) {
      throw const FormatException('Unsupported input map version.');
    }
    final actions = _list(data['actions']), bindings = _list(data['bindings']);
    if (actions.length > 128 || bindings.length > 512) {
      throw const FormatException('Input map exceeds limits.');
    }
    return GameInputMap(
      actions: actions.map((item) {
        final a = _map(item);
        return GameActionDefinition(
          _string(a['id']),
          button: a['button'] as bool,
          deadZone: (a['deadZone'] as num).toDouble(),
        );
      }).toList(),
      bindings: bindings.map((item) {
        final b = _map(item);
        return GameInputBinding(
          _string(b['control']),
          _string(b['action']),
          scale: (b['scale'] as num).toDouble(),
        );
      }).toList(),
    );
  }
}
