import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'support/offline_fixture.dart' show offlineResource;

GeoResourceKey fieldKey(String id) => GeoResourceKey(
  sourceId: id,
  sourceVersion: 'fixture-1',
  authorizationPartition: 'public',
  address: 'grid',
  representation: 'scalar-grid-f64',
  decoderVersion: 1,
);
void main() {
  test(
    'cold offline coast and bathymetry retain finite coverage and provenance',
    () async {
      final directory = await Directory.systemTemp.createTemp('zyren-fields-');
      var store = FileGeoDataStore(
        directory: directory,
        maxBytes: 65536,
        maxEntries: 4,
      );
      const bounds = GeographicRectangle(0, 0, 1, 1);
      final depth = GeoScalarGrid(
        width: 2,
        height: 2,
        bounds: bounds,
        values: Float64List.fromList([10, 30, 20, 40]),
      );
      final coast = GeoScalarGrid(
        width: 2,
        height: 2,
        bounds: bounds,
        values: Float64List.fromList([0, 1, 0, 1]),
      );
      await store.write(offlineResource(fieldKey('depth'), depth.encode()));
      await store.write(offlineResource(fieldKey('coast'), coast.encode()));
      await store.close();
      store = FileGeoDataStore(
        directory: directory,
        maxBytes: 65536,
        maxEntries: 4,
      );
      var calls = 0;
      final resolver = GeoResourceResolver(
        store: store,
        fetch: (_, _) async {
          calls++;
          throw StateError('forbidden');
        },
      );
      final bathymetry = GeoGridFieldSource(
        id: 'bathymetry',
        units: 'm depth',
        datum: GeoHeightDatum.meanSeaLevel,
        key: fieldKey('depth'),
        bounds: bounds,
        resolver: resolver,
        policy: GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
        errorBound: 0,
      );
      final mask = GeoGridFieldSource(
        id: 'coast',
        units: 'water fraction',
        datum: null,
        key: fieldKey('coast'),
        bounds: bounds,
        resolver: resolver,
        policy: GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
        interpolation: GeoFieldInterpolation.nearest,
      );
      final time = GeoInstant(tick: 120, hz: 60, epoch: DateTime.utc(2026));
      final value = await bathymetry.sample(Geodetic(.25, .5), time);
      expect(value.value, closeTo(20, 1e-12));
      expect(value.units, 'm depth');
      expect(value.sourceRevision, 'fixture-1');
      expect(value.time, time);
      expect((await mask.sample(Geodetic(.2, .5), time)).value, 0);
      expect((await mask.sample(Geodetic(.8, .5), time)).value, 1);
      expect(
        (await bathymetry.sample(Geodetic(2, .5), time)).availability,
        GeoSampleAvailability.outsideCoverage,
      );
      expect(calls, 0);
      expect(bathymetry.decodedBytes, 32);
      bathymetry.dispose();
      mask.dispose();
      expect(
        (await bathymetry.sample(Geodetic(.25, .5), time)).availability,
        GeoSampleAvailability.failed,
      );
      await resolver.close();
      await store.close();
      await directory.delete(recursive: true);
    },
  );
  test(
    'missing cells and malformed fields never become zero-height samples',
    () {
      const bounds = GeographicRectangle(0, 0, 1, 1);
      final grid = GeoScalarGrid(
        width: 2,
        height: 2,
        bounds: bounds,
        values: Float64List.fromList([1, double.nan, 3, 4]),
      );
      expect(grid.at(Geodetic(.5, .5), GeoFieldInterpolation.bilinear), isNull);
      final bytes = grid.encode();
      bytes[0] = 0;
      expect(
        () => GeoScalarGrid.decode(bytes),
        throwsA(isA<GeoDataException>()),
      );
    },
  );
}
