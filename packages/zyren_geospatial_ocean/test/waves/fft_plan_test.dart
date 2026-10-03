import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test('each Stockham row stage matches the four-value butterfly fixture', () {
    final input = Float64List(32)..setRange(0, 8, [1, 0, 2, 0, 3, 0, 4, 0]);
    final plan = OceanFftPlan(4);
    final first = plan.stages[0].apply(input, 4);
    expect(first.take(8), [4, 0, -2, 0, 6, 0, -2, 0]);
    final second = plan.stages[1].apply(first, 4);
    for (var i = 0; i < 8; i++) {
      expect(second[i], closeTo([10, 0, -2, -2, -2, 0, -2, 2][i], 1e-12));
    }
    var transformed = input;
    for (final stage in plan.stages) {
      transformed = stage.apply(transformed, 4);
    }
    final oracle = inverseDft2(input, 4);
    for (var i = 0; i < oracle.length; i++) {
      expect(transformed[i], closeTo(oracle[i], 1e-12));
    }
  });
}
