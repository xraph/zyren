import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

void main() {
  test('a Dart VM builds a renderable scene without a Flutter engine', () {
    final scene = Scene()..add(Mesh(BoxGeometry(), MeshMaterial()));
    final frame = scene.snapshot(PerspectiveCamera(), 1);
    expect(frame['meshes'], hasLength(1));
    expect(frame['geometries'], hasLength(1));
    expect(frame['version'], 1);
  });
}
