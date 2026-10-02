import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

Vec3 vector(List value) => Vec3(
  (value[0] as num).toDouble(),
  (value[1] as num).toDouble(),
  (value[2] as num).toDouble(),
);
void main() {
  test('cascades match original TypeScript under both camera projections', () {
    final fixture = jsonDecode(
      File('test/fixtures/clouds/cascades.json').readAsStringSync(),
    );
    for (final v in fixture['cases'] as List) {
      final position = vector(v['position']), target = vector(v['target']);
      final Camera camera = v['orthographic'] as bool
          ? OrthographicCamera(
              position: position,
              target: target,
              left: -1500,
              right: 2500,
              top: 2000,
              bottom: -1000,
              near: (v['near'] as num).toDouble(),
              far: 300000,
              zoom: (v['zoom'] as num).toDouble(),
            )
          : PerspectiveCamera(
              position: position,
              target: target,
              fieldOfView: 3.141592653589793 / 3,
              near: 1,
              far: 300000,
              zoom: (v['zoom'] as num).toDouble(),
            );
      for (final depth in DepthStrategy.values) {
        camera.depthStrategy = depth;
        final cascades = CloudShadowCascades.build(
          camera: camera,
          aspect: 1.5,
          sunDirection: vector(v['sun']),
          count: v['count'],
          mapWidth: 256,
          mapHeight: 256,
          maxFar: 200000,
          margin: 100,
          distance: 50000,
          splitMode: v['splitMode'] == 'uniform'
              ? CloudShadowSplit.uniform
              : CloudShadowSplit.practical,
        );
        expect(cascades.cascades.length, v['count']);
        for (var i = 0; i < cascades.cascades.length; i++) {
          final actual = cascades.cascades[i], expected = v['result'][i];
          for (final pair in [
            (actual.matrix, expected['matrix']),
            (actual.inverseMatrix, expected['inverse']),
            (actual.projectionMatrix, expected['projection']),
            (actual.viewMatrix, expected['view']),
            (actual.inverseViewMatrix, expected['inverseView']),
          ]) {
            for (var j = 0; j < 16; j++) {
              expect(
                pair.$1.storage[j],
                closeTo((pair.$2[j] as num).toDouble(), .000002),
                reason:
                    'case ${v['orthographic']}/${v['position']}, cascade $i, element $j',
              );
            }
          }
          expect(
            actual.interval.$1,
            closeTo((expected['interval'][0] as num).toDouble(), 1e-12),
          );
          expect(
            actual.interval.$2,
            closeTo((expected['interval'][1] as num).toDouble(), 1e-12),
          );
        }
      }
    }
  });
  test('cascade inputs are finite, bounded and immutable', () {
    final camera = PerspectiveCamera();
    expect(
      () => CloudShadowCascades.build(
        camera: camera,
        aspect: 1,
        sunDirection: Vec3.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudShadowCascades.build(
        camera: camera,
        aspect: 1,
        sunDirection: const Vec3(1, 0, 0),
        count: 5,
      ),
      throwsRangeError,
    );
    expect(
      () => CloudShadowCascades.build(
        camera: camera,
        aspect: 1,
        sunDirection: const Vec3(1, 0, 0),
        splitLambda: double.nan,
      ),
      throwsArgumentError,
    );
    final result = CloudShadowCascades.build(
      camera: camera,
      aspect: 1,
      sunDirection: const Vec3(1, 0, 0),
    );
    expect(() => result.cascades.clear(), throwsUnsupportedError);
    final ortho = OrthographicCamera(near: 0);
    expect(
      CloudShadowCascades.build(
        camera: ortho,
        aspect: 1,
        sunDirection: const Vec3(1, 0, 0),
      ).cascades.length,
      3,
    );
  });
}
