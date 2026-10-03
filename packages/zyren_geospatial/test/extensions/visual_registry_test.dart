import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'visual styles retain immutable versioned configuration and scoped ownership',
    () {
      final registry = GeoVisualRegistry();
      final settings = <String, Object?>{
        'color': [0.1, 0.4, 0.8],
      };
      final style = GeoVisualStyle(
        id: 'ocean',
        owner: 'water',
        version: 1,
        configuration: settings,
      );
      final token = registry.registerStyle(style);
      settings['color'] = [1, 1, 1];
      expect(registry.style('ocean', 1)!.configuration['color'], [
        0.1,
        0.4,
        0.8,
      ]);
      expect(() => registry.registerStyle(style), throwsStateError);
      token.dispose();
      expect(registry.style('ocean', 1), isNull);
    },
  );
  test(
    'pass validation rejects missing dependencies, cycles and exclusive conflicts',
    () {
      GeoVisualPass pass(
        String name, {
        Set<String> after = const {},
        Set<String> exclusive = const {},
      }) => GeoVisualPass(
        name: name,
        owner: name,
        after: after,
        exclusive: exclusive,
      );
      expect(
        () => GeoVisualRegistry.validatePasses([
          pass('a', after: {'b'}),
        ]),
        throwsStateError,
      );
      expect(
        () => GeoVisualRegistry.validatePasses([
          pass('a', after: {'b'}),
          pass('b', after: {'a'}),
        ]),
        throwsStateError,
      );
      expect(
        () => GeoVisualRegistry.validatePasses([
          pass('a', exclusive: {'environment'}),
          pass('b', exclusive: {'environment'}),
        ]),
        throwsStateError,
      );
      expect(
        GeoVisualRegistry.validatePasses([
          pass('b', after: {'a'}),
          pass('a'),
        ]).map((p) => p.name),
        ['a', 'b'],
      );
    },
  );
}
