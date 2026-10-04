import 'package:zyren_game/training.dart';

(double, double) multiLayoutRange(TrainingSplit split) => switch (split) {
  TrainingSplit.training => (-.1, .1),
  TrainingSplit.validation => (.15, .25),
  TrainingSplit.test => (-.25, -.15),
};

double multiLayoutOffset(int seed, TrainingSplit split) {
  if (seed < 0 || seed >= 1 << 31) {
    throw ArgumentError.value(seed, 'seed', 'Expected a bounded episode seed.');
  }
  var bits = seed ^ 0x9e3779b9;
  bits = ((bits ^ (bits >> 16)) * 0x85ebca6b) & 0xffffffff;
  bits = ((bits ^ (bits >> 13)) * 0xc2b2ae35) & 0xffffffff;
  bits = (bits ^ (bits >> 16)) & 0xffffffff;
  final (low, high) = multiLayoutRange(split);
  return low + (high - low) * (bits / 4294967296);
}
