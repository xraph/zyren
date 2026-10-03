part of 'asset_scope.dart';

/// A bounded LRU of decoded recipes shared by asset scopes.
/// You own this cache: close scopes separately, then [dispose] the cache.
/// Clearing or evicting recipes leaves delivered assets valid.
class AssetCache {
  final int maxEntries;
  final int maxDecodedBytes;
  final _entries = <(AssetServices, _LoadKey), _DecodedRecipe<Object>>{};
  int _decodedBytes = 0;
  int _generation = 0;
  bool _disposed = false;

  AssetCache({this.maxEntries = 64, this.maxDecodedBytes = 128 * 1024 * 1024}) {
    RangeError.checkValueInInterval(maxEntries, 1, 0x7fffffff, 'maxEntries');
    RangeError.checkValueInInterval(
      maxDecodedBytes,
      1,
      0x7fffffff,
      'maxDecodedBytes',
    );
  }

  int get length => _entries.length;
  int get decodedBytes => _decodedBytes;
  bool get isDisposed => _disposed;

  _DecodedRecipe<T>? _get<T extends Object>(
    AssetServices services,
    _LoadKey key,
  ) {
    if (_disposed) throw StateError('Asset cache has been disposed.');
    final cacheKey = (services, key);
    final entry = _entries.remove(cacheKey);
    if (entry == null) return null;
    _entries[cacheKey] = entry;
    return entry as _DecodedRecipe<T>;
  }

  void _put<T extends Object>(
    AssetServices services,
    _LoadKey key,
    _DecodedRecipe<T> entry,
    int generation,
  ) {
    if (_disposed ||
        entry._invalidated ||
        generation != _generation ||
        entry.bytes > maxDecodedBytes) {
      return;
    }
    final cacheKey = (services, key);
    final old = _entries.remove(cacheKey);
    if (old != null) {
      _decodedBytes -= old.bytes;
      old._caches.remove(this);
      old.release();
    }
    entry.retain();
    _entries[cacheKey] = entry;
    entry._caches.add(this);
    _decodedBytes += entry.bytes;
    while (_entries.length > maxEntries || _decodedBytes > maxDecodedBytes) {
      _remove(_entries.keys.first);
    }
  }

  void _discard<T extends Object>(
    AssetServices services,
    _LoadKey key,
    _DecodedRecipe<T> recipe,
  ) {
    if (identical(_entries[(services, key)], recipe)) _remove((services, key));
  }

  void _remove((AssetServices, _LoadKey) key) {
    final entry = _entries.remove(key);
    if (entry == null) return;
    _decodedBytes -= entry.bytes;
    entry._caches.remove(this);
    entry.release();
  }

  /// Removes this request's recipe and prevents pending jobs from restoring it.
  void evict<T extends Object>(
    AssetServices services,
    AssetRequest<T> request,
  ) {
    _generation++;
    _remove((services, _loadKey(request)));
  }

  /// Also invalidates cache admission for jobs that were already pending.
  void clear() {
    _generation++;
    for (final key in List.of(_entries.keys)) {
      _remove(key);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clear();
  }
}

class _DecodedRecipe<T extends Object> {
  final DecodedAsset<T> decoded;
  final _SharedLoadPool pool;
  final _LoadKey key;
  final int bytes;
  final _caches = Set<AssetCache>.identity();
  bool _invalidated = false;
  int _holds = 1;
  _DecodedRecipe(this.decoded, this.pool, this.key, this.bytes);

  void invalidate() {
    if (_invalidated) return;
    _invalidated = true;
    for (final cache in List.of(_caches)) {
      cache._discard(pool.services, key, this);
    }
  }

  void retain() => _holds++;
  void release() {
    if (--_holds == 0) pool.cleanup(decoded.dispose);
  }
}
