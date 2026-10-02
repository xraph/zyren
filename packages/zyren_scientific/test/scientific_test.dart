import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_scientific/zyren_scientific.dart';

final kelvin = ScientificUnit(quantity: 'temperature', symbol: 'K');
final metres = ScientificUnit(quantity: 'length', symbol: 'm');
final source = ScientificSource(
  id: 'fixture:affine:v1',
  description: 'Synthetic T(i,j,k) = 10 + 2i + 3j + 5k',
  kind: ScientificDataKind.synthetic,
);

ScalarGrid3D grid({
  int x = 3,
  int y = 4,
  int z = 3,
  List<double?>? values,
  Vec3 origin = Vec3.zero,
  Vec3 spacing = Vec3.one,
  ScientificBudget? budget,
}) => ScalarGrid3D(
  sizeX: x,
  sizeY: y,
  sizeZ: z,
  values:
      values ??
      [
        for (var k = 0; k < z; k++)
          for (var j = 0; j < y; j++)
            for (var i = 0; i < x; i++) 10.0 + 2 * i + 3 * j + 5 * k,
      ],
  origin: origin,
  spacing: spacing,
  valueUnit: kelvin,
  coordinateUnit: metres,
  source: source,
  name: 'Temperature',
  budget: budget,
);
ScalarTransferFunction transfer({double min = 10, double max = 33}) =>
    ScalarTransferFunction(
      unit: kelvin,
      minimum: min,
      maximum: max,
      stops: [
        TransferStop(0, const Color3(0, 0, 1)),
        TransferStop(1, const Color3(1, 0, 0)),
      ],
    );
ScalarSlice slice(
  ScalarGrid3D field, {
  SliceAxis axis = SliceAxis.z,
  double index = .5,
  double tolerance = 1e-5,
  ScientificBudget? budget,
}) => ScalarSlice.build(
  grid: field,
  transfer: transfer(),
  axis: axis,
  index: index,
  coordinateTolerance: tolerance,
  budget: budget,
);

void main() {
  group('data', () {
    test(
      'copies input, retains explicit units/source and distinguishes zero',
      () {
        final input = <double?>[0, null, 3, 4];
        final field = grid(x: 2, y: 2, z: 1, values: input);
        input[0] = 999;
        expect(field.valueAt(0, 0, 0), 0);
        expect(field.valueAt(1, 0, 0), isNull);
        expect(field.validCount, 3);
        expect(field.missingCount, 1);
        expect(field.range!.minimum, 0);
        expect(field.range!.maximum, 4);
        expect(field.payloadBytes, 36);
        expect(field.valueUnit, kelvin);
        expect(field.coordinateUnit, metres);
        expect(field.source.id, 'fixture:affine:v1');
        expect(field.source.kind, ScientificDataKind.synthetic);
        expect(() => field.valueAt(-1, 0, 0), throwsRangeError);
        expect(() => field.valueAt(2, 0, 0), throwsRangeError);
        expect(() => field.valueAt(0, 2, 0), throwsRangeError);
        expect(() => field.valueAt(0, 0, 1), throwsRangeError);
      },
    );
    test('rejects invalid values, dimensions, budgets and coordinates', () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => grid(x: 1, y: 1, z: 1, values: [value]),
          throwsArgumentError,
        );
      }
      expect(() => grid(x: 0), throwsArgumentError);
      expect(
        () => grid(x: 0x7fffffffffffffff, values: []),
        throwsArgumentError,
      );
      expect(() => grid(values: []), throwsArgumentError);
      expect(
        () => grid(budget: ScientificBudget(maxSamples: 35)),
        throwsArgumentError,
      );
      expect(() => grid(spacing: const Vec3(-1, 1, 1)), throwsArgumentError);
      expect(() => grid(origin: const Vec3(1e308, 0, 0)), throwsArgumentError);
      expect(() => grid(spacing: const Vec3(1e308, 1, 1)), throwsArgumentError);
      expect(() => ScientificBudget(maxGeometryBytes: 0), throwsArgumentError);
      expect(
        () => ScientificUnit(quantity: '', symbol: 'K'),
        throwsArgumentError,
      );
      expect(
        () => ScientificSource(
          id: '',
          description: 'x',
          kind: ScientificDataKind.measured,
        ),
        throwsArgumentError,
      );
    });
    test('all missing has no fabricated range', () {
      final field = grid(x: 2, y: 2, z: 1, values: [null, null, null, null]);
      expect(field.range, isNull);
      expect(field.validCount, 0);
      expect(field.missingCount, 4);
    });
  });
  group('transfer', () {
    test('endpoints, clipping, midpoint and linear RGB', () {
      final map = transfer(min: 0, max: 100);
      expect(map.map(null), isNull);
      expect(map.map(-100), const Color3(0, 0, 1));
      expect(map.map(200), const Color3(1, 0, 0));
      expect(map.map(25), const Color3(.25, 0, .75));
      expect(transfer(min: 3, max: 3).map(3), const Color3(.5, 0, .5));
      expect(() => map.map(double.nan), throwsArgumentError);
    });
    test('piecewise stops are copied and interpolate independently', () {
      final stops = [
        TransferStop(0, const Color3(0, 0, 0)),
        TransferStop(.25, const Color3(0, 1, 0)),
        TransferStop(1, const Color3(1, 1, 1)),
      ];
      final map = ScalarTransferFunction(
        unit: kelvin,
        minimum: 0,
        maximum: 1,
        stops: stops,
      );
      stops.clear();
      expect(map.map(.125), const Color3(0, .5, 0));
      expect(map.map(.625), const Color3(.5, 1, .5));
      expect(() => map.stops.clear(), throwsUnsupportedError);
    });
    test('rejects invalid ranges/stops/colors', () {
      expect(() => transfer(min: 2, max: 1), throwsArgumentError);
      expect(() => transfer(min: -1e308, max: 1e308), throwsArgumentError);
      expect(
        () => TransferStop(double.nan, const Color3(0, 0, 0)),
        throwsArgumentError,
      );
      expect(() => TransferStop(0, const Color3(2, 0, 0)), throwsArgumentError);
      expect(
        () => TransferStop(0, const Color3(double.nan, 0, 0)),
        throwsArgumentError,
      );
      for (final stops in <List<TransferStop>>[
        [],
        [TransferStop(0, const Color3(0, 0, 0))],
        [
          TransferStop(.2, const Color3(0, 0, 0)),
          TransferStop(1, const Color3(1, 1, 1)),
        ],
        [
          TransferStop(0, const Color3(0, 0, 0)),
          TransferStop(0, const Color3(1, 1, 1)),
          TransferStop(1, const Color3(1, 1, 1)),
        ],
      ]) {
        expect(
          () => ScalarTransferFunction(
            unit: kelvin,
            minimum: 0,
            maximum: 1,
            stops: stops,
          ),
          throwsArgumentError,
        );
      }
    });
  });
  group('slice', () {
    test('affine field agrees on all axes within 1e-12 K', () {
      for (final axis in SliceAxis.values) {
        final result = slice(grid(), axis: axis, index: .25);
        for (var v = 0; v < result.height; v++) {
          for (var u = 0; u < result.width; u++) {
            final expected = switch (axis) {
              SliceAxis.x => 10 + 2 * .25 + 3 * u + 5 * v,
              SliceAxis.y => 10 + 2 * v + 3 * .25 + 5 * u,
              SliceAxis.z => 10 + 2 * u + 3 * v + 5 * .25,
            };
            expect(result.valueAt(u, v), closeTo(expected, 1e-12));
          }
        }
        expect(result.omittedCells, 0);
        expect(
          result.geometryBytes,
          result.width * result.height * 36 + result.renderedCells * 24,
        );
        final mesh = result.createMesh()!;
        final normal = Vec3.array(mesh.geometry.normals);
        final a = Vec3.array(
          mesh.geometry.positions,
          mesh.geometry.indices[0] * 3,
        );
        final b = Vec3.array(
          mesh.geometry.positions,
          mesh.geometry.indices[1] * 3,
        );
        final c = Vec3.array(
          mesh.geometry.positions,
          mesh.geometry.indices[2] * 3,
        );
        expect((b - a).cross(c - a).dot(normal), greaterThan(0));
        expect(mesh.position, result.origin);
        expect(mesh.name, contains('synthetic'));
        expect(mesh.material.vertexColors, isTrue);
        expect(mesh.material.unlit, isTrue);
      }
    });
    test('missing neighbors only remove contributing cells', () {
      final values = List<double?>.filled(18, 1)..[9] = null;
      final field = grid(x: 3, y: 3, z: 2, values: values);
      expect(slice(field, index: 0).renderedCells, 4);
      final result = slice(field, index: .5);
      expect(result.valueAt(0, 0), isNull);
      expect(result.omittedCells, 1);
      expect(result.renderedCells, 3);
      expect(result.geometry!.indices, isNot(contains(0)));
      expect(slice(field, index: 1).omittedCells, 1);
      expect(() => result.valueAt(3, 0), throwsRangeError);
    });
    test('an empty slice does not allocate a fake zero-value mesh', () {
      final result = slice(
        grid(x: 2, y: 2, z: 1, values: [null, 0, 0, 0]),
        index: 0,
      );
      expect(result.isEmpty, isTrue);
      expect(result.omittedCells, 1);
      expect(result.createMesh(), isNull);
      expect(result.geometryBytes, 0);
      expect(result.valueAt(1, 1), 0);
    });
    test('large origins preserve millimetre-local geometry', () {
      final result = slice(
        grid(
          origin: const Vec3(1e9, -1e9, 1e9),
          spacing: const Vec3(.001, .001, .001),
        ),
      );
      expect(result.maxCoordinateError, lessThan(2e-10));
      expect(result.createMesh()!.geometry.positions[3], closeTo(.001, 1e-10));
      expect(result.origin.x, 1e9);
      expect(result.origin.z, 1e9 + .0005);
      expect(
        () => slice(grid(spacing: const Vec3(.001, 1, 1)), tolerance: 0),
        throwsArgumentError,
      );
      expect(
        () => slice(grid(spacing: const Vec3(1e40, 1, 1)), tolerance: 1e40),
        throwsArgumentError,
      );
      expect(
        () => slice(grid(spacing: const Vec3(1e-50, 1, 1)), tolerance: 1),
        throwsArgumentError,
      );
    });
    test('rejects invalid slice requests and preflights budgets', () {
      for (final index in [-1.0, 3.0, double.nan, double.infinity]) {
        expect(() => slice(grid(), index: index), throwsRangeError);
      }
      expect(() => slice(grid(), tolerance: -1), throwsArgumentError);
      expect(() => slice(grid(x: 1)), throwsArgumentError);
      expect(
        () => slice(grid(), budget: ScientificBudget(maxSliceCells: 5)),
        throwsArgumentError,
      );
      expect(
        () => slice(grid(), budget: ScientificBudget(maxGeometryBytes: 575)),
        throwsArgumentError,
      );
      expect(
        slice(
          grid(),
          budget: ScientificBudget(maxGeometryBytes: 576),
        ).geometryBytes,
        576,
      );
      expect(
        () => ScalarSlice.build(
          grid: grid(),
          transfer: ScalarTransferFunction(
            unit: ScientificUnit(quantity: 'temperature', symbol: 'degC'),
            minimum: 0,
            maximum: 100,
            stops: [
              TransferStop(0, const Color3(0, 0, 0)),
              TransferStop(1, const Color3(1, 1, 1)),
            ],
          ),
          axis: SliceAxis.z,
          index: 0,
          coordinateTolerance: 1e-5,
        ),
        throwsArgumentError,
      );
    });
    test('reports transfer range clipping without changing data', () {
      final result = slice(
        grid(x: 2, y: 2, z: 1, values: [-1, 10, 33, 50]),
        index: 0,
      );
      expect(result.belowRangeSamples, 1);
      expect(result.aboveRangeSamples, 1);
      expect(result.valueAt(1, 1), 50);
    });
  });
}
