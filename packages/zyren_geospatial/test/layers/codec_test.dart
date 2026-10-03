import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

GeoLayerConfigurationCodec<int> terrainCodec() =>
    GeoLayerConfigurationCodec<int>(
      kind: 'terrain',
      schemaVersion: 2,
      encode: (size) => {'size': size},
      decode: (json) => json['size'] as int,
      migrations: {
        1: (json) => {'size': json['oldSize']},
      },
    );

void main() {
  test(
    'restored definitions can be adopted once with real runtime capabilities',
    () {
      final source = GeoLayerController();
      source.register(
        GeoLayer(id: 'a', owner: 'test', kind: 'terrain', visible: false),
      );
      final target = GeoLayerController();
      GeoLayerCodec(target).decode(GeoLayerCodec(source).encode());
      final runtime = GeoLayer(
        id: 'a',
        owner: 'test',
        kind: 'terrain',
        capabilities: {GeoLayerCapability.query},
      );
      final claim = target.register(runtime, adoptRestored: true);
      expect(target.layer('a').visible, isFalse);
      expect(target.layer('a').capabilities, {GeoLayerCapability.query});
      expect(
        () => target.register(runtime, adoptRestored: true),
        throwsStateError,
      );
      claim.dispose();
      expect(target.snapshot, isEmpty);
    },
  );

  test('restoring configuration retains matching ownership registrations', () {
    final layers = GeoLayerController();
    final token = layers.register(
      GeoLayer(id: 'g', owner: 'test', kind: 'group'),
    );
    final codec = GeoLayerCodec(layers);
    codec.decode(codec.encode());
    token.dispose();
    expect(layers.snapshot, isEmpty);
  });

  test('missing migration preserves the original unresolved configuration', () {
    final source = GeoLayerController();
    source.register(
      GeoLayer(
        id: 'a',
        owner: 'test',
        kind: 'terrain',
        configuration: {'oldSize': 32},
      ),
    );
    final target = GeoLayerController();
    final codec = GeoLayerCodec(target);
    codec.register(
      GeoLayerConfigurationCodec<int>(
        kind: 'terrain',
        schemaVersion: 3,
        encode: (v) => {'size': v},
        decode: (v) => v['size'] as int,
        migrations: {
          1: (v) => {'middle': v['oldSize']},
        },
      ),
    );
    codec.decode(GeoLayerCodec(source).encode());
    expect(target.layer('a').configurationIssue, contains('No migration'));
    expect(target.layer('a').configurationVersion, 1);
    expect(target.layer('a').configuration, {'oldSize': 32});
  });

  test(
    'documents round trip ordering, policies, versions and unresolved configuration',
    () {
      final layers = GeoLayerController();
      layers.transact(0, (e) {
        e.add(
          GeoLayer(
            id: 'future',
            owner: 'future',
            kind: 'custom',
            configurationVersion: 9,
            configuration: {
              'field': [1, 'two'],
            },
            sourceReference: 'ocean-data',
            sourceRevision: '2026.4',
            styleRevision: 'blue-3',
            policies: const GeoLayerPolicies(queryWhenHidden: true),
          ),
        );
      });
      final document = GeoLayerCodec(layers).encode();
      final restored = GeoLayerController();
      final codec = GeoLayerCodec(restored);
      codec.decode(document);
      final layer = restored.layer('future');
      expect(layer.configurationIssue, isNotNull);
      expect(layer.status.data, GeoLayerDataState.unavailable);
      expect(layer.configuration, {
        'field': [1, 'two'],
      });
      expect(layer.configurationVersion, 9);
      expect(layer.sourceRevision, '2026.4');
      expect(layer.styleRevision, 'blue-3');
      expect(layer.policies.queryWhenHidden, isTrue);
      expect(codec.encode(), document);
      expect(
        () => (layer.configuration['field'] as List).clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('registered migrations resolve configuration before publication', () {
    final source = GeoLayerController();
    source.transact(
      0,
      (e) => e.add(
        GeoLayer(
          id: 'a',
          owner: 'test',
          kind: 'terrain',
          configuration: {'oldSize': 32},
        ),
      ),
    );
    final target = GeoLayerController();
    final codec = GeoLayerCodec(target);
    final registration = codec.register(terrainCodec());
    codec.decode(GeoLayerCodec(source).encode());
    expect(target.layer('a').configuration, {'size': 32});
    expect(target.layer('a').configurationVersion, 2);
    expect(target.layer('a').configurationIssue, isNull);
    expect(codec.configuration<int>('a'), 32);
    registration.dispose();
    expect(() => codec.configuration<int>('a'), throwsStateError);
  });

  test('invalid and oversized documents do not replace live layers', () {
    final layers = GeoLayerController();
    layers.transact(
      0,
      (e) => e.add(GeoLayer(id: 'keep', owner: 'test', kind: 'group')),
    );
    final codec = GeoLayerCodec(layers, maxDocumentBytes: 2048);
    final original = layers.snapshot;
    for (final config in <Map<String, Object?>>[
      {'password': 'secret'},
      {'url': 'https://example.test/?token=secret'},
      {'x': double.nan},
      {'handle': Object()},
      {'large': 'x' * 3000},
    ]) {
      final document = codec.encode();
      final entry = (document['layers'] as List).single as Map<String, Object?>;
      entry['configuration'] = config;
      expect(() => codec.decode(document), throwsArgumentError);
      expect(layers.snapshot, same(original));
      expect(layers.revision, 1);
    }
    final invalid = codec.encode();
    ((invalid['layers'] as List).single as Map)['parentId'] = 'missing';
    expect(() => codec.decode(invalid), throwsArgumentError);
    expect(layers.snapshot, same(original));
  });
}
