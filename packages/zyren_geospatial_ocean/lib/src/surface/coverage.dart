import 'cube_patch.dart';

/// Exact dyadic coverage of six cube faces. This certifies mesh topology only;
/// it does not classify land, water or availability of geographic source data.
final class OceanPatchCoverage {
  final List<OceanPatchId> patches;
  bool get complete => true;
  OceanPatchCoverage(Iterable<OceanPatchId> patches)
    : patches = List.unmodifiable(patches.take(4097)) {
    final set = this.patches.toSet();
    if (set.length != this.patches.length ||
        set.length < 6 ||
        set.length > 4096) {
      throw ArgumentError('Invalid bounded patch cover.');
    }
    final area = List.filled(6, 0);
    for (final p in set) {
      area[p.face] += 1 << (2 * (20 - p.level));
      for (var parent = p.parent; parent != null; parent = parent.parent) {
        if (set.contains(parent)) {
          throw ArgumentError('Ocean patch coverage overlaps.');
        }
      }
    }
    if (area.any((a) => a != 1 << 40)) {
      throw ArgumentError('Ocean patch coverage has a hole.');
    }
  }
}
