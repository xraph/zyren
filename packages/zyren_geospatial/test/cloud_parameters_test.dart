import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/clouds/defaults.json').readAsStringSync(),
  );
  test(
    'cloud layer defaults and empty intervals match original TypeScript',
    () {
      expect(CloudLayer().toJson(), fixture['layerDefault']);
      for (final c in fixture['cases']) {
        final layers = CloudLayers(
          (c['layers'] as List).map(
            (l) => CloudLayer.fromJson(Map<String, dynamic>.from(l)),
          ),
        );
        final values = c['values'];
        expect(layers.layers.map((l) => l.toJson()).toList(), c['layers']);
        expect(
          layers.gaps.map((v) => v.$1).toList(),
          values['minIntervalHeights'],
        );
        expect(
          layers.gaps.map((v) => v.$2).toList(),
          values['maxIntervalHeights'],
        );
        expect(layers.minimumAltitude, values['minHeight']);
        expect(layers.maximumAltitude, values['maxHeight']);
        expect(layers.shadowBottom, values['shadowBottomHeight']);
        expect(layers.shadowTop, values['shadowTopHeight']);
      }
      expect(
        CloudLayers.defaults().layers.map((l) => l.toJson()).toList(),
        fixture['cases'][0]['layers'],
      );
    },
  );
  test('all source quality presets and shared cloud parameters match', () {
    for (final preset in CloudQualityPreset.values) {
      expect(
        CloudQuality.forPreset(preset).toJson(),
        fixture['qualityPresets'][preset.name],
      );
    }
    final p = CloudParameters();
    final reference = fixture['parameters'];
    expect(p.coverage, reference['coverage']);
    expect(p.scatteringCoefficient, reference['scatteringCoefficient']);
    expect(p.absorptionCoefficient, reference['absorptionCoefficient']);
    expect(p.turbulenceDisplacement, reference['turbulenceDisplacement']);
    expect([
      p.localWeatherRepeat.$1,
      p.localWeatherRepeat.$2,
    ], reference['localWeatherRepeat']);
    expect(p.shapeRepeat.storage, reference['shapeRepeat']);
    expect(p.shapeDetailRepeat.storage, reference['shapeDetailRepeat']);
    expect([
      p.turbulenceRepeat.$1,
      p.turbulenceRepeat.$2,
    ], reference['turbulenceRepeat']);
    expect(p.shapeVelocity, Vec3.zero);
  });
  test('cloud values are immutable, finite and bounded before GPU work', () {
    final input = [CloudLayer(height: 100)];
    final layers = CloudLayers(input);
    input.clear();
    expect(layers.layers.length, 4);
    expect(layers.layers.first.height, 100);
    expect(() => layers.layers.clear(), throwsUnsupportedError);
    expect(
      () => CloudLayers(List.generate(5, (_) => CloudLayer())),
      throwsArgumentError,
    );
    for (final invalid in [-1.0, double.nan, double.infinity]) {
      expect(() => CloudLayer(height: invalid), throwsArgumentError);
      expect(() => CloudParameters(coverage: invalid), throwsArgumentError);
    }
    expect(() => CloudParameters(coverage: 1.01), throwsArgumentError);
    expect(() => CloudLayer(channel: 4), throwsArgumentError);
    for (final channel in ['', 'rg', 'red', 'x']) {
      expect(
        () => CloudLayer.fromJson({'channel': channel}),
        throwsArgumentError,
      );
    }
    expect(
      () => CloudLayer(altitude: 90000, height: 20000),
      throwsArgumentError,
    );
    expect(() => CloudParameters(shapeRepeat: Vec3.zero), throwsArgumentError);
    expect(
      () => CloudDensityProfile(exponent: double.infinity),
      throwsArgumentError,
    );
    final density = CloudDensityProfile(linearTerm: .75, constantTerm: .25);
    expect(density.sample(0), .25);
    expect(density.sample(1), 1);
    expect(() => density.sample(double.nan), throwsArgumentError);
  });
}
