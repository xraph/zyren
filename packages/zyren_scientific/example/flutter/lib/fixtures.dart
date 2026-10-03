import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_scientific/zyren_scientific.dart';

final temperatureUnit = ScientificUnit(quantity: 'temperature', symbol: 'K');
final coordinateUnit = ScientificUnit(quantity: 'length', symbol: 'm');
final velocityUnit = ScientificUnit(quantity: 'velocity', symbol: 'm/s');
final scientificFixtureSource = ScientificSource(
  id: 'synthetic:thermal-pulse:v1',
  description: 'Analytic Gaussian temperature pulse',
  kind: ScientificDataKind.synthetic,
);
ScalarGrid3D syntheticField({double time = 2}) => ScalarGrid3D(
  sizeX: 21,
  sizeY: 21,
  sizeZ: 21,
  values: [
    for (var z = 0; z < 21; z++)
      for (var y = 0; y < 21; y++)
        for (var x = 0; x < 21; x++)
          273 +
              40 *
                  (.6 + .2 * time) *
                  math.exp(
                    -4 *
                        ((x - 10) * (x - 10) +
                            (y - 10) * (y - 10) +
                            (z - 10) * (z - 10)) *
                        .01,
                  ),
  ],
  origin: const Vec3(-1, -1, -1),
  spacing: const Vec3(.1, .1, .1),
  valueUnit: temperatureUnit,
  coordinateUnit: coordinateUnit,
  source: scientificFixtureSource,
  name: 'Temperature',
);
ScalarTransferFunction syntheticTransfer() => ScalarTransferFunction(
  unit: temperatureUnit,
  minimum: 273,
  maximum: 313,
  stops: [
    TransferStop(0, const Color3(.015, .08, .3)),
    TransferStop(.5, const Color3(0, .7, .85)),
    TransferStop(1, const Color3(1, .2, .03)),
  ],
);
VectorGrid3D syntheticVectors() {
  final source = ScientificSource(
    id: 'synthetic:rotation:v1',
    description: 'Steady rotation about the Z axis',
    kind: ScientificDataKind.synthetic,
  );
  ScalarGrid3D component(int axis) => ScalarGrid3D(
    sizeX: 21,
    sizeY: 21,
    sizeZ: 21,
    values: [
      for (var z = 0; z < 21; z++)
        for (var y = 0; y < 21; y++)
          for (var x = 0; x < 21; x++)
            axis == 0
                ? -(y - 10) * .1
                : axis == 1
                ? (x - 10) * .1
                : 0.0,
    ],
    origin: const Vec3(-1, -1, -1),
    spacing: const Vec3(.1, .1, .1),
    valueUnit: velocityUnit,
    coordinateUnit: coordinateUnit,
    source: source,
    name: 'Velocity component $axis',
  );
  return VectorGrid3D(
    x: component(0),
    y: component(1),
    z: component(2),
    basis: VectorBasis.cartesian(),
  );
}

TemporalScalarSource syntheticTime() => TemporalScalarSource(
  source: scientificFixtureSource,
  timeUnit: ScientificUnit(quantity: 'time', symbol: 's'),
  frames: [
    for (var i = 0; i < 3; i++)
      ScientificFrameKey(id: 'thermal:$i', version: '1', time: i.toDouble()),
  ],
  load: (key, token) async {
    token.check();
    return syntheticField(time: key.time);
  },
);
