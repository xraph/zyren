import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

void main() {
  final results = <Map<String, Object>>[];
  for (final acceleration in RaycastAcceleration.values) {
    for (final instances in [false, true]) {
      final scene = Scene();
      final void Function(int) edit;
      if (instances) {
        final mesh = scene.add(
          InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 10000),
        );
        mesh.setTransforms(
          0,
          List.generate(
            10000,
            (i) => Mat4.compose(
              Vec3((i % 100) * 2.0, (i ~/ 100) * 2.0, 0),
              Quat.identity,
              Vec3.one,
            ),
          ),
        );
        edit = (i) => mesh.setTransform(
          0,
          Mat4.compose(Vec3(0, 0, i.isEven ? .1 : .2), Quat.identity, Vec3.one),
        );
      } else {
        final positions = <double>[], normals = <double>[], indices = <int>[];
        for (var y = 0; y <= 128; y++) {
          for (var x = 0; x <= 128; x++) {
            positions.addAll([x - 64.0, y - 64.0, 0]);
            normals.addAll([0, 0, 1]);
          }
        }
        for (var y = 0; y < 128; y++) {
          for (var x = 0; x < 128; x++) {
            final a = y * 129 + x;
            indices.addAll([a, a + 1, a + 130, a, a + 130, a + 129]);
          }
        }
        final geometry = BufferGeometry(
          positions: positions,
          normals: normals,
          indices: indices,
          dynamic: true,
        );
        scene.add(Mesh(geometry, UnlitMaterial()));
        edit = (i) => geometry.updateAttribute(
          VertexSemantic.position,
          Float32List.fromList([0, 0, i.isEven ? .1 : .2]),
          firstVertex: 64 * 129 + 64,
        );
      }
      final caster = Raycaster(acceleration: acceleration);
      Map<String, Object> sample(int i) {
        final ray = Ray(
          Vec3(.13 + (i % 7) * .01, .21, 5),
          const Vec3(0, 0, -1),
        );
        final clock = Stopwatch()..start();
        final snapshot = caster.capture(scene, ray);
        final capture = clock.elapsedMicroseconds;
        final report = snapshot.trace();
        final elapsed = clock.elapsedMicroseconds;
        if (report.hits.isEmpty) throw StateError('Benchmark fixture missed.');
        final stats = report.statistics;
        return {
          'captureMs': capture / 1000,
          'queryMs': (elapsed - capture) / 1000,
          'totalMs': elapsed / 1000,
          'geometryBuilds': stats.geometryBuilds,
          'geometryRefits': stats.geometryRefits,
          'sceneBuilds': stats.sceneBuilds,
          'sceneRefits': stats.sceneRefits,
          'modelMatrixInversions': stats.modelMatrixInversions,
          'meshTests': stats.meshTests,
          'bvhBoundsTests': stats.bvhBoundsTests,
          'triangleTests': stats.triangleTests,
        };
      }

      final cold = sample(0);
      for (var i = 0; i < 10; i++) {
        sample(i);
      }
      final steady = [for (var i = 0; i < 40; i++) sample(i)];
      final changed = <Map<String, Object>>[];
      for (var i = 0; i < 20; i++) {
        edit(i);
        changed.add(sample(i));
      }
      Map<String, Object> summary(List<Map<String, Object>> samples) => {
        for (final key in ['captureMs', 'queryMs', 'totalMs'])
          key: percentiles(samples.map((s) => s[key] as double).toList()),
        'sampleCounters': {
          for (final entry in samples.last.entries)
            if (!entry.key.endsWith('Ms')) entry.key: entry.value,
        },
      };
      results.add({
        'fixture': instances ? '10000 instances' : '32768 triangles',
        'acceleration': acceleration.name,
        'cold': cold,
        'steady': summary(steady),
        'oneEdit': summary(changed),
      });
    }
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'runtime': Platform.version.split('\n').first,
      'os': Platform.operatingSystem,
      'warmup': 10,
      'steadySamples': 40,
      'editSamples': 20,
      'measurement':
          'CPU capture and nearest-hit query only; no renderer or GPU',
      'results': results,
    }),
  );
}

Map<String, double> percentiles(List<double> values) {
  values.sort();
  return {
    'p50': values[values.length ~/ 2],
    'p95': values[(values.length * .95).ceil() - 1],
  };
}
