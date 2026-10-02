part of 'scene.dart';

/// Deterministic screen-space coverage for built-in material transitions.
/// Complementary intervals [0, t) and [t, 1) retain full combined coverage.
/// Geometric picking excludes empty intervals but does not sample the hash.
final class FragmentCoverage {
  final double lower, upper;
  const FragmentCoverage.full() : lower = 0, upper = 1;
  FragmentCoverage({this.lower = 0, this.upper = 1}) {
    if (!lower.isFinite ||
        !upper.isFinite ||
        lower < 0 ||
        upper > 1 ||
        lower > upper) {
      throw ArgumentError(
        'Fragment coverage must be an ordered interval within [0, 1].',
      );
    }
  }
  bool get isFull => lower == 0 && upper == 1;
  bool get isEmpty => lower == upper;
  @override
  bool operator ==(Object other) =>
      other is FragmentCoverage && lower == other.lower && upper == other.upper;
  @override
  int get hashCode => Object.hash(lower, upper);
}
