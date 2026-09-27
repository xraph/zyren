import 'dart:convert';
import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

void main() {
  final data =
      jsonDecode(File('test/fixtures/picking.json').readAsStringSync())
          as Map<String, dynamic>;
  List<double> numbers(Object? value) =>
      (value as List).cast<num>().map((v) => v.toDouble()).toList();
  Vec3 vector(Object? value) => Vec3.array(numbers(value));
  final geometries = <String, BufferGeometry>{
    for (final entry in (data['geometries'] as Map<String, dynamic>).entries)
      entry.key: BufferGeometry(
        positions: numbers(entry.value['positions']),
        normals: numbers(entry.value['normals']),
        indices: (entry.value['indices'] as List).cast<int>(),
        uv0: numbers(entry.value['uv0']),
      ),
  };
  for (final row in data['cases'] as List) {
    test(
      'r184 picking ${row['projection']} ${row['origin']} ${row['scale']}',
      () {
        final scene = Scene()..position = vector(row['origin']);
        final q = numbers(row['quaternion']);
        final group = scene.add(Group())
          ..position = vector(row['position'])
          ..quaternion = Quat(q[0], q[1], q[2], q[3])
          ..scale = vector(row['scale']);
        for (final info in data['meshes'] as List) {
          group
              .add(
                Mesh(
                  geometries[info['geometry']]!,
                  UnlitMaterial(),
                  name: info['geometry'] as String,
                ),
              )
              .position = vector(
            info['position'],
          );
        }
        final picker = Raycaster();
        for (final sample in row['rays'] as List) {
          final hits = picker.intersectScene(
            scene,
            CameraRay(vector(sample['origin']), vector(sample['direction'])),
          );
          final expected = sample['hits'] as List;
          expect(hits.length, expected.length);
          for (var i = 0; i < hits.length; i++) {
            final hit = hits[i], want = expected[i];
            expect(hit.object.name, want['name']);
            expect(hit.triangleIndex, want['triangle']);
            expect(
              hit.distance,
              closeTo((want['distance'] as num).toDouble(), 1e-8),
            );
            for (var axis = 0; axis < 3; axis++) {
              expect(
                hit.point.storage[axis],
                closeTo(numbers(want['point'])[axis], 1e-8),
              );
              expect(
                hit.normal.storage[axis],
                closeTo(numbers(want['normal'])[axis], 1e-8),
              );
            }
            expect(hit.uv!.u, closeTo(numbers(want['uv'])[0], 1e-8));
            expect(hit.uv!.v, closeTo(numbers(want['uv'])[1], 1e-8));
          }
        }
      },
    );
  }
}
