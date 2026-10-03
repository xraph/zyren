import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'picks use stable identity and deletion clears selection atomically',
    () {
      final layers = GeoLayerController();
      final hit = GeoFeatureHit(
        layerId: 'a',
        featureId: 'vessel-4',
        position: Geodetic.degrees(179, 25),
        sourceRevision: 'v2',
        metadata: {'name': 'Vessel'},
      );
      layers.transact(0, (e) {
        e.add(GeoLayer(id: 'a', owner: 'test', kind: 'ocean'));
        e.select([hit.identity, hit.identity]);
      });
      expect(layers.selection.snapshot, [const GeoFeatureId('a', 'vessel-4')]);
      expect(
        () => layers.transact(
          1,
          (e) => e.select([const GeoFeatureId('missing', 'x')]),
        ),
        throwsArgumentError,
      );
      expect(layers.revision, 1);
      layers.transact(1, (e) => e.remove('a'));
      expect(layers.selection.snapshot, isEmpty);
    },
  );
}
