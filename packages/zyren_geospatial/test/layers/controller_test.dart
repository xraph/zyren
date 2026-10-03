import 'dart:async';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

GeoLayer tile(
  String id, {
  String? parentId,
  Set<GeoLayerCapability>? capabilities,
}) => GeoLayer(
  id: id,
  owner: 'test',
  kind: 'terrain',
  parentId: parentId,
  capabilities: capabilities ?? GeoLayerCapability.values.toSet(),
);

void main() {
  test(
    'view filters do not change loading, retention or simulation policy',
    () {
      final layers = GeoLayerController();
      final at = DateTime.utc(2026, 10, 3);
      layers.transact(
        0,
        (e) => e.add(
          GeoLayer(
            id: 'a',
            owner: 'test',
            kind: 'terrain',
            filter: GeoLayerFilter(
              minimumDistance: 10,
              maximumMetresPerPixel: 100,
              start: at,
              end: at.add(const Duration(hours: 1)),
            ),
            status: GeoLayerStatus(
              lifecycle: GeoLayerLifecycle.attached,
              data: GeoLayerDataState.ready,
            ),
          ),
        ),
      );
      expect(
        layers.visibleAt('a', distance: 5, metresPerPixel: 1, time: at),
        isFalse,
      );
      expect(
        layers.visibleAt('a', distance: 20, metresPerPixel: 1, time: at),
        isTrue,
      );
      expect(
        layers.visibleAt('a', distance: 20, metresPerPixel: 101, time: at),
        isFalse,
      );
      expect(
        layers.visibleAt(
          'a',
          distance: 20,
          metresPerPixel: 1,
          time: at.add(const Duration(hours: 2)),
        ),
        isFalse,
      );
      expect(layers.layer('a').status.data, GeoLayerDataState.ready);
      expect(
        layers.layer('a').policies.simulation,
        GeoHiddenSimulation.continueRunning,
      );
    },
  );

  test('foreign children survive scoped group removal', () {
    final layers = GeoLayerController();
    final group = layers.register(
      GeoLayer(id: 'g', owner: 'one', kind: 'group'),
    );
    final child = layers.register(
      GeoLayer(id: 'c', owner: 'two', kind: 'terrain', parentId: 'g'),
    );
    group.dispose();
    expect(layers.snapshot.single.id, 'c');
    expect(layers.snapshot.single.parentId, isNull);
    child.dispose();
    expect(layers.snapshot, isEmpty);
  });

  test('cycles leave layer state and revision unchanged', () {
    final layers = GeoLayerController();
    layers.transact(0, (edit) {
      edit.add(GeoLayer(id: 'a', owner: 'test', kind: 'group'));
      edit.add(GeoLayer(id: 'b', owner: 'test', kind: 'group', parentId: 'a'));
    });
    final before = layers.snapshot;
    expect(
      () => layers.transact(1, (e) => e.reparent('a', 'b')),
      throwsArgumentError,
    );
    expect(layers.revision, 1);
    expect(layers.snapshot, same(before));
    expect(layers.snapshot.first.parentId, isNull);
  });

  test(
    'one atomic change covers edits, inherited state and selection',
    () async {
      final layers = GeoLayerController();
      final changes = <GeoLayerChange>[];
      final subscription = layers.changes.listen(changes.add);
      layers.transact(0, (e) {
        e.add(GeoLayer(id: 'group', owner: 'test', kind: 'group'));
        e.add(tile('a', parentId: 'group'));
        e.add(tile('b', parentId: 'group'));
        e.setOpacity('group', .5);
        e.setOpacity('a', .4);
        e.select([const GeoFeatureId('a', 'ship')]);
      });
      expect(layers.effectiveOpacity('a'), closeTo(.2, 1e-12));
      expect(layers.selection.snapshot, [const GeoFeatureId('a', 'ship')]);
      layers.transact(1, (e) {
        e.setVisible('group', false);
        e.move('b', 0);
      });
      expect(layers.snapshot.map((e) => e.id), ['group', 'b', 'a']);
      expect(layers.effectiveVisible('a'), isFalse);
      expect(layers.effectiveQueryable('a'), isFalse);
      layers.transact(
        2,
        (e) =>
            e.setPolicies('a', const GeoLayerPolicies(queryWhenHidden: true)),
      );
      expect(layers.effectiveQueryable('a'), isTrue);
      layers.transact(3, (e) => e.remove('a'));
      expect(layers.selection.snapshot, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(4));
      expect(changes.last.removedIds, {'a'});
      expect(changes.last.selection, isEmpty);
      await subscription.cancel();
      await layers.dispose();
    },
  );

  test('invalid operations and stale or reentrant edits publish nothing', () {
    final layers = GeoLayerController();
    layers.transact(0, (e) {
      e.add(tile('a'));
      e.add(tile('b', capabilities: {}));
    });
    final before = layers.snapshot;
    for (final operation in <void Function(GeoLayerEdit)>[
      (e) => e.add(tile('a')),
      (e) => e.reparent('a', 'missing'),
      (e) => e.move('a', 2),
      (e) => e.move('b', 0),
      (e) => e.setOpacity('b', .2),
      (e) => e.setOpacity('a', double.nan),
      (e) {
        e.setVisible('a', false);
        e.setOpacity('b', .5);
      },
    ]) {
      expect(() => layers.transact(1, operation), throwsArgumentError);
      expect(layers.snapshot, same(before));
      expect(layers.revision, 1);
    }
    expect(() => layers.transact(0, (e) => e.remove('a')), throwsStateError);
    expect(
      () => layers.transact(1, (e) => layers.setVisible('a', false)),
      throwsStateError,
    );
    expect(layers.revision, 1);
    GeoLayerEdit? escaped;
    layers.transact(1, (e) => escaped = e);
    expect(() => escaped!.remove('a'), throwsStateError);
    expect(layers.snapshot, hasLength(2));
  });

  test('owned removal, generation checks and failures preserve survivors', () {
    final layers = GeoLayerController();
    final old = layers.register(tile('a'));
    final first = layers.beginLoad('a');
    final second = layers.beginLoad('a');
    expect(
      first.publish(GeoLayerStatus(data: GeoLayerDataState.ready)),
      isFalse,
    );
    expect(
      second.publish(GeoLayerStatus(data: GeoLayerDataState.empty)),
      isTrue,
    );
    expect(layers.layer('a').status.data, GeoLayerDataState.empty);
    old.dispose();
    final replacement = layers.register(tile('a'));
    old.dispose();
    expect(
      second.publish(GeoLayerStatus(data: GeoLayerDataState.failed)),
      isFalse,
    );
    expect(layers.layer('a').status.data, GeoLayerDataState.unavailable);
    replacement.dispose();
    expect(layers.snapshot, isEmpty);
  });

  test(
    'non-capable descendants reject group opacity, children require explicit removal',
    () {
      final layers = GeoLayerController();
      layers.transact(0, (e) {
        e.add(GeoLayer(id: 'group', owner: 'test', kind: 'group'));
        e.add(tile('child', parentId: 'group', capabilities: {}));
      });
      expect(
        () => layers.transact(1, (e) => e.setOpacity('group', .5)),
        throwsArgumentError,
      );
      expect(
        () => layers.transact(1, (e) => e.remove('group')),
        throwsArgumentError,
      );
      layers.transact(1, (e) => e.remove('group', descendants: true));
      expect(layers.snapshot, isEmpty);
    },
  );

  test(
    'bounds preserve dateline and polar coverage, unknown remains unknown',
    () {
      final coverage = GeoLayerCoverage(
        bounds: GeographicRectangle(
          170 * math.pi / 180,
          -math.pi / 2,
          -170 * math.pi / 180,
          math.pi / 2,
        ),
      );
      expect(coverage.contains(Geodetic.degrees(179, 0)), isTrue);
      expect(coverage.contains(Geodetic.degrees(-179, 90)), isTrue);
      expect(coverage.contains(Geodetic.degrees(0, 0)), isFalse);
      expect(const GeoLayerCoverage().contains(Geodetic.degrees(0, 0)), isNull);
    },
  );

  test(
    'disposal during notification is safe and prevents later edits',
    () async {
      final layers = GeoLayerController();
      final disposed = Completer<void>();
      layers.changes.listen((_) {
        layers.dispose().then((_) => disposed.complete());
      });
      layers.transact(0, (e) => e.add(tile('a')));
      await disposed.future;
      expect(() => layers.setVisible('a', false), throwsStateError);
    },
  );
}
