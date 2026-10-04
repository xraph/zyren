import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  test('caller changes cannot mutate a pinned sensor or action contract', () {
    final fields = [ObservationField('value')];
    final observation = ObservationSpec(id: 'immutable', fields: fields);
    final observationHash = observation.hash;
    fields.add(ObservationField('later'));
    expect(observation.fields.length, 1);
    expect(observation.hash, observationHash);
    expect(
      observation.hash,
      ObservationSpec(id: 'immutable', fields: [fields.first]).hash,
    );

    final materials = {SensorMaterial.glass: SensorMaterialRule.pass};
    final profile = SensorProfile(materials: materials);
    final profileHash = profile.hash;
    materials[SensorMaterial.glass] = SensorMaterialRule.block;
    expect(profile.materials[SensorMaterial.glass], SensorMaterialRule.pass);
    expect(profile.hash, profileHash);

    final choices = ['idle', 'walk'];
    final branches = [ActionBranch('move', choices: choices)];
    final fallback = [0];
    final action = ActionSpec(
      id: 'immutable',
      branches: branches,
      fallbackDiscrete: fallback,
    );
    final actionHash = action.hash;
    choices.add('run');
    branches.clear();
    fallback[0] = 1;
    expect(action.branches.single.choices, ['idle', 'walk']);
    expect(action.fallbackDiscrete, [0]);
    expect(action.hash, actionHash);
    expect(action.accepts([], [2]), isFalse);
  });
  test('ordered schemas pin units, bounds, normalization and slot limits', () {
    final x = ObservationField('x', units: 'metres', min: -10, max: 10);
    final y = ObservationField('y', units: 'metres', min: -10, max: 10);
    final a = ObservationSpec(id: 'vision', fields: [x, y], maxEntities: 2);
    final b = ObservationSpec(id: 'vision', fields: [y, x], maxEntities: 2);
    expect(a.hash, isNot(b.hash));
    expect(
      a.hash,
      ObservationSpec(id: 'vision', fields: [x, y], maxEntities: 2).hash,
    );
    expect(() => a.fields.add(x), throwsUnsupportedError);
    expect(
      () => ObservationSpec(id: 'bad', fields: [x, x]),
      throwsArgumentError,
    );
    expect(
      () => ObservationField('bad', min: double.nan, max: 1),
      throwsArgumentError,
    );
    expect(
      () => ObservationField('overflow', min: -1, max: 1, scale: 1e-300),
      throwsArgumentError,
    );
  });

  test(
    'actions declare continuous limits, branch legality and a valid fallback',
    () {
      final spec = ActionSpec(
        id: 'character',
        continuous: [
          ObservationField('speed', units: 'metres/second', min: 0, max: 4),
        ],
        branches: [
          ActionBranch('stance', choices: ['stand', 'crouch']),
        ],
        fallbackContinuous: [0],
        fallbackDiscrete: [0],
      );
      expect(
        spec.accepts(
          [3],
          [1],
          legality: [
            [true, true],
          ],
        ),
        isTrue,
      );
      expect(
        spec.accepts(
          [3],
          [1],
          legality: [
            [true, false],
          ],
        ),
        isFalse,
      );
      expect(spec.accepts([double.nan], [0]), isFalse);
      expect(spec.accepts([5], [0]), isFalse);
      expect(
        () => ActionSpec(
          id: 'bad',
          continuous: spec.continuous,
          fallbackContinuous: [7],
        ),
        throwsArgumentError,
      );
      expect(spec.hash.length, 64);
    },
  );
}
