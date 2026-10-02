import 'package:test/test.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

import '../example/triangle_source.dart';

Future<PipelineBundle> bundle(double width) {
  final source = TriangleSource(width: width);
  return PipelineBuilder(
    resolver: source,
  ).build(entrySourceId: 'model', sources: source.sources);
}

void main() {
  test(
    'source invalidation purges all revisions but preserves open assets',
    () async {
      final a = await bundle(1), b = await bundle(2);
      final cache = PipelineCache();
      cache.put(a);
      cache.put(b);
      final scope = cache.get(a.version)!.open();
      final model = await scope.load(a.gltfRequest()).result;
      final removed = cache.invalidateSource('positions');
      expect(removed.toSet(), {a.version, b.version});
      expect(cache.length, 0);
      expect(cache.byteLength, 0);
      expect(cache.get(a.version), isNull);
      expect(model.instantiate().children, isNotEmpty);
      final pinned = await scope.load(a.gltfRequest()).result;
      expect(pinned.sourceUri, a.gltfRequest().uri);
      await scope.close();
      expect(model.isReleased, isTrue);
      expect(pinned.isReleased, isTrue);
    },
  );

  test(
    'LRU access and limits evict the least recently loaded bundle',
    () async {
      final a = await bundle(1), b = await bundle(2), c = await bundle(3);
      final cache = PipelineCache(
        maxBytes: a.byteLength + b.byteLength,
        maxBundles: 2,
      );
      cache.put(a);
      cache.put(b);
      cache.get(a.version);
      cache.put(c);
      expect(cache.peek(a.version), same(a));
      expect(cache.peek(b.version), isNull);
      expect(cache.peek(c.version), same(c));
      expect(cache.byteLength, a.byteLength + c.byteLength);
      expect(cache.invalidateVersion(a.version), isTrue);
      expect(cache.invalidateVersion(a.version), isFalse);
      expect(cache.byteLength, c.byteLength);
      cache.clear();
      expect(cache.byteLength, 0);
    },
  );

  test(
    'inspection and oversized admission leave cache contents unchanged',
    () async {
      final a = await bundle(1), b = await bundle(10000);
      final cache = PipelineCache(maxBytes: a.byteLength);
      expect(cache.put(a), isTrue);
      final revision = cache.revision;
      expect(cache.put(b), isFalse);
      expect(cache.peek(a.version), same(a));
      expect(cache.bundles, [a]);
      expect(cache.revision, revision);
      expect(cache.put(a), isTrue);
      expect(cache.byteLength, a.byteLength);
      expect(cache.revision, revision);
    },
  );

  test('entry count also bounds zero and small payload bundles', () async {
    final a = await bundle(1), b = await bundle(2);
    final cache = PipelineCache(maxBundles: 1);
    cache.put(a);
    cache.put(b);
    expect(cache.bundles, [b]);
    expect(cache.invalidateSource('unknown'), isEmpty);
  });
}
