import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/multi_layout.dart';

void main() {
  test('TRAIN, development and TEST use disjoint physical offset ranges', () {
    for (final split in TrainingSplit.values) {
      final values = [
        for (var seed = 0; seed < 200; seed++) multiLayoutOffset(seed, split),
      ];
      expect(values.toSet(), hasLength(200));
      final (low, high) = multiLayoutRange(split);
      expect(values.every((v) => v >= low && v < high), isTrue);
      expect(multiLayoutOffset(17, split), values[17]);
    }
    expect(
      () => multiLayoutOffset(-1, TrainingSplit.training),
      throwsArgumentError,
    );
    expect(
      () => multiLayoutOffset(1 << 31, TrainingSplit.training),
      throwsArgumentError,
    );
  });
}
