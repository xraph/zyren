part of '../../zyren_game_ai.dart';

final class ActionBranch {
  final String name;
  final List<String> choices;
  ActionBranch(this.name, {required List<String> choices})
    : choices = List.unmodifiable(choices) {
    _name(name);
    _bounded(choices.length, 256, 'choices');
    for (final choice in choices) {
      _name(choice);
    }
    if (choices.toSet().length != choices.length) {
      throw ArgumentError('Duplicate branch choice.');
    }
  }
  Map<String, Object> toJson() => {'name': name, 'choices': choices};
}

final class ActionSpec {
  final String id;
  final int version;
  final List<ObservationField> continuous;
  final List<ActionBranch> branches;
  final List<double> fallbackContinuous;
  final List<int> fallbackDiscrete;
  ActionSpec({
    required this.id,
    this.version = 1,
    List<ObservationField> continuous = const [],
    List<ActionBranch> branches = const [],
    List<double> fallbackContinuous = const [],
    List<int> fallbackDiscrete = const [],
  }) : continuous = List.unmodifiable(continuous),
       branches = List.unmodifiable(branches),
       fallbackContinuous = List.unmodifiable(fallbackContinuous),
       fallbackDiscrete = List.unmodifiable(fallbackDiscrete) {
    _name(id);
    _bounded(version, 65535, 'version');
    final names = [
      ...continuous.map((f) => f.name),
      ...branches.map((b) => b.name),
    ];
    if (names.isEmpty ||
        names.length > 128 ||
        names.toSet().length != names.length ||
        continuous.any((f) => f.width != 1) ||
        !accepts(fallbackContinuous, fallbackDiscrete)) {
      throw ArgumentError('Invalid action schema or fallback.');
    }
  }
  bool accepts(
    List<double> values,
    List<int> choices, {
    List<List<bool>>? legality,
  }) {
    if (values.length != continuous.length ||
        choices.length != branches.length ||
        (legality != null && legality.length != branches.length)) {
      return false;
    }
    for (var i = 0; i < values.length; i++) {
      if (!continuous[i].accepts(values[i])) return false;
    }
    for (var i = 0; i < choices.length; i++) {
      final choice = choices[i];
      if (choice < 0 ||
          choice >= branches[i].choices.length ||
          (legality != null &&
              (legality[i].length != branches[i].choices.length ||
                  !legality[i][choice]))) {
        return false;
      }
    }
    return true;
  }

  String get hash => _hash(toJson());
  Map<String, Object> toJson() => {
    'id': id,
    'version': version,
    'continuous': continuous.map((f) => f.toJson()).toList(),
    'branches': branches.map((b) => b.toJson()).toList(),
    'fallbackContinuous': fallbackContinuous,
    'fallbackDiscrete': fallbackDiscrete,
  };
}
