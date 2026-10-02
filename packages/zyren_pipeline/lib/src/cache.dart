import 'bundle.dart';

/// LRU cache of immutable original-byte bundles. The budget counts payload bytes,
/// not decoded assets, JSON serialization, metadata or references held by callers.
final class PipelineCache {
  final int maxBytes, maxBundles;
  final _bundles = <String, PipelineBundle>{};
  int _bytes = 0, _revision = 0;
  PipelineCache({this.maxBytes = 128 * 1024 * 1024, this.maxBundles = 32}) {
    RangeError.checkValueInInterval(maxBytes, 1, 0x7fffffff, 'maxBytes');
    RangeError.checkValueInInterval(maxBundles, 1, 4096, 'maxBundles');
  }

  int get byteLength => _bytes;
  int get length => _bundles.length;
  int get revision => _revision;

  /// Snapshot in eviction order. Inspection does not touch recency or revision.
  List<PipelineBundle> get bundles => List.unmodifiable(_bundles.values);
  PipelineBundle? peek(String version) => _bundles[version];

  /// A normal cache read updates eviction order. Returned bundles remain valid
  /// even after invalidation; their asset scopes own their decoded resources.
  PipelineBundle? get(String version) {
    final bundle = _bundles.remove(version);
    if (bundle != null) _bundles[version] = bundle;
    return bundle;
  }

  /// Oversized admission fails without evicting existing entries.
  bool put(PipelineBundle bundle) {
    if (bundle.byteLength > maxBytes) return false;
    if (_bundles.containsKey(bundle.version)) {
      get(bundle.version);
      return true;
    }
    while (_bundles.length >= maxBundles ||
        _bytes + bundle.byteLength > maxBytes) {
      _remove(_bundles.keys.first);
    }
    _bundles[bundle.version] = bundle;
    _bytes += bundle.byteLength;
    _revision++;
    return true;
  }

  bool invalidateVersion(String version) {
    if (!_bundles.containsKey(version)) return false;
    _remove(version);
    return true;
  }

  /// Removes every cached bundle that contains this upstream source identity.
  List<String> invalidateSource(String sourceId) {
    final versions = [
      for (final entry in _bundles.entries)
        if (entry.value.resources.any((r) => r.source.sourceId == sourceId))
          entry.key,
    ];
    for (final version in versions) {
      _remove(version);
    }
    return List.unmodifiable(versions);
  }

  void clear() {
    if (_bundles.isEmpty) return;
    _bundles.clear();
    _bytes = 0;
    _revision++;
  }

  void _remove(String version) {
    final bundle = _bundles.remove(version)!;
    _bytes -= bundle.byteLength;
    _revision++;
  }
}
