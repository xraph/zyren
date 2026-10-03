import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../extensions/composition_test.dart' show create;
import 'identity_test.dart' show key, resource;
import 'resolver_test.dart' show error;

void main() {
  test(
    'data services follow extension scope while the host keeps store ownership',
    () async {
      final store = MemoryGeoDataStore(maxBytes: 100, maxEntries: 4);
      final resolver = GeoResourceResolver(
        store: store,
        fetch: (k, _) async => resource(k),
      );
      final diagnostics = GeoDataDiagnostics(
        resolver: resolver,
        inspectTiers: () async => GeoDataTiers(
          encodedMemoryBytes: store.usedBytes,
          decodedCpuBytes: 0,
        ),
      );
      final geo = GeospatialPlugin(
        extensions: [
          GeoDataExtension(
            store: store,
            resolver: resolver,
            diagnostics: diagnostics,
          ),
        ],
      );
      final engine = await create(geo.scenePlugins);
      expect(geo.registry.find(geospatialDataStore), same(store));
      expect(geo.registry.find(geospatialDataDiagnostics), same(diagnostics));
      await engine.dispose();
      expect(geo.registry.find(geospatialDataStore), isNull);
      expect(await store.write(resource(key())), isTrue);
      await resolver.close();
      await store.close();
    },
  );
  test(
    'unknown tiers remain null and failure reporting keeps resource identity',
    () async {
      final store = MemoryGeoDataStore(maxBytes: 100, maxEntries: 4);
      final resolver = GeoResourceResolver(
        store: store,
        fetch: (k, _) async => resource(k),
      );
      final diagnostics = GeoDataDiagnostics(
        resolver: resolver,
        inspectTiers: () async =>
            throw const GeoDataException(GeoDataError.corrupt),
      );
      await expectLater(
        diagnostics.trackSource(
          key(),
          () async =>
              throw const GeoDataException(GeoDataError.transportFailure),
        ),
        error(GeoDataError.transportFailure),
      );
      await diagnostics.trackSource(
        key(sourceVersion: 'other'),
        () async => resource(key(sourceVersion: 'other')),
      );
      final snapshot = await diagnostics.snapshot();
      expect(snapshot.tiers, isNull);
      expect(snapshot.storeFailure, GeoDataError.corrupt);
      expect(snapshot.physicalGpuResidentBytes, isNull);
      expect(snapshot.failures.single.keyDigest, key().digest);
      expect(snapshot.transportAttempts, 2);
      await diagnostics.trackSource(key(), () async => resource(key()));
      expect((await diagnostics.snapshot()).failures, isEmpty);
      await resolver.close();
      await store.close();
    },
  );
}
