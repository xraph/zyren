import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  final cut = ClippingPlane(normal: const Vec3(1, 0, 0));
  test('convex box caps face outward and obey every half-space', () {
    final result = buildSectionCaps(BoxGeometry(), Mat4.identity(), [
      cut,
      ClippingPlane(normal: const Vec3(0, 1, 0)),
    ]);
    expect(result.issue, isNull);
    expect(result.geometries, hasLength(2));
    for (final g in result.geometries) {
      for (var i = 0; i < g.positions.length; i += 3) {
        final p = Vec3.array(g.positions, i);
        expect(p.x, greaterThanOrEqualTo(-1e-8));
        expect(p.y, greaterThanOrEqualTo(-1e-8));
      }
      for (var i = 0; i < g.positions.length; i += 9) {
        final a = Vec3.array(g.positions, i);
        final b = Vec3.array(g.positions, i + 3);
        final c = Vec3.array(g.positions, i + 6);
        expect(
          (b - a).cross(c - a).dot(Vec3.array(g.normals, i)),
          greaterThan(0),
        );
      }
    }
  });
  test('open and duplicate faces fail without filling their boundary', () {
    final box = BoxGeometry();
    for (final indices in [
      box.indices.sublist(3),
      [...box.indices, ...box.indices],
    ]) {
      final result = buildSectionCaps(
        BufferGeometry(
          positions: box.positions,
          normals: box.normals,
          indices: indices,
        ),
        Mat4.identity(),
        [cut],
      );
      expect(result.issue, SectionCapIssue.openOrNonManifold);
      expect(result.geometries, isEmpty);
    }
  });
  test('concave geometry fails without producing a false solid', () {
    final box = BoxGeometry();
    final positions = [...box.positions];
    for (var i = 0; i < positions.length; i += 3) {
      if (positions[i] == .5 &&
          positions[i + 1] == .5 &&
          positions[i + 2] == .5) {
        positions[i] = 0;
        positions[i + 1] = 0;
        positions[i + 2] = 0;
      }
    }
    final result = buildSectionCaps(
      BufferGeometry(
        positions: positions,
        normals: box.normals,
        indices: box.indices,
      ),
      Mat4.identity(),
      [cut],
    );
    expect(result.issue, SectionCapIssue.nonConvex);
    expect(result.geometries, isEmpty);
  });
  test('oblique caps retain area through a sheared reflected hierarchy', () {
    final parent = Group()..scale = const Vec3(-2, 1, 3);
    final child = parent.add(Group()..rotateY(.7));
    final world = parent.localMatrix * child.localMatrix;
    final plane = ClippingPlane(normal: const Vec3(1, 2, 3));
    final result = buildSectionCaps(BoxGeometry(), world, [plane]);
    expect(result.issue, isNull);
    expect(result.geometries, hasLength(1));
    final g = result.geometries.single;
    for (var i = 0; i < g.positions.length; i += 3) {
      expect(plane.distanceTo(Vec3.array(g.positions, i)), closeTo(0, 2e-7));
    }
  });
  test('tangent and outside planes do not add a cap', () {
    for (final offset in [.5, 2.0]) {
      expect(
        buildSectionCaps(BoxGeometry(), Mat4.identity(), [
          ClippingPlane(normal: const Vec3(1, 0, 0), offset: offset),
        ]).geometries,
        isEmpty,
      );
    }
  });
  test(
    'transformed caps refresh, preserve materials and release ownership',
    () async {
      final source = Mesh(BoxGeometry(), UnlitMaterial());
      final original = source.material;
      final scene = Scene()..add(Group()..add(source));
      final sections = SceneSectionPlugin(capMaterial: UnlitMaterial());
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [sections],
      );
      try {
        sections.setCapTargets([source]);
        sections.setPlanes([cut]);
        expect(sections.capMeshes, hasLength(1));
        final first = sections.capMeshes.single;
        expect(first.outlineEnabled, isFalse);
        expect(source.material, same(original));
        await engine.render(width: 8, height: 8, elapsed: Duration.zero);
        expect(sections.capMeshes.single, same(first));
        source.position = const Vec3(.25, 0, 0);
        source.scale = const Vec3(-2, 1, 1);
        await engine.render(width: 8, height: 8, elapsed: Duration.zero);
        expect(first.parent, isNull);
        final replacement = sections.capMeshes.single;
        for (var i = 0; i < replacement.geometry.positions.length; i += 3) {
          expect(
            Vec3.array(replacement.geometry.positions, i).x,
            closeTo(.125, 1e-7),
          );
        }
        source.position = const Vec3(1000000000, 0, 0);
        sections.setPlanes([
          ClippingPlane(normal: const Vec3(1, 0, 0), offset: 1000000000.25),
        ]);
        final distant = sections.capMeshes.single.geometry;
        for (var i = 0; i < distant.positions.length; i += 3) {
          expect(distant.positions[i], closeTo(-.125, 1e-7));
        }
        source.visible = false;
        await engine.render(width: 8, height: 8, elapsed: Duration.zero);
        expect(sections.capMeshes, isEmpty);
        source.visible = true;
        await engine.render(width: 8, height: 8, elapsed: Duration.zero);
        expect(sections.capMeshes, hasLength(1));
        scene.clippingPlanes = [];
        await engine.render(width: 8, height: 8, elapsed: Duration.zero);
        expect(sections.capMeshes, isEmpty);
        expect(source.children, isEmpty);
      } finally {
        await engine.dispose();
      }
    },
  );
}
