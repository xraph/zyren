import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';
import '../../zyren/test/support/fakes.dart';
import 'support/cap_fixtures.dart';

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
  test('concave prisms preserve their notch and multiple-plane area', () {
    final cutZ = ClippingPlane(normal: const Vec3(0, 0, 1));
    final whole = buildSectionCaps(concaveCapPrism(), Mat4.identity(), [cutZ]);
    expect(whole.issue, isNull);
    expect(capArea(whole.geometries.single), closeTo(3, 1e-6));
    final clipped = buildSectionCaps(concaveCapPrism(), Mat4.identity(), [
      cutZ,
      ClippingPlane(normal: const Vec3(1, 0, 0), offset: 1.5),
    ]);
    expect(clipped.issue, isNull);
    expect(capArea(clipped.geometries.first), closeTo(.5, 1e-6));
  });
  test(
    'nested cavity contours and disconnected shells preserve their areas',
    () {
      final plane = ClippingPlane(normal: const Vec3(0, 0, 1));
      final cavity = combineCapShells([
        (BoxGeometry(width: 4, height: 4, depth: 4), Vec3.zero),
        (BoxGeometry(width: 2, height: 2, depth: 2), Vec3.zero),
      ]);
      final hollow = buildSectionCaps(cavity, Mat4.identity(), [plane]);
      expect(hollow.issue, isNull);
      expect(capArea(hollow.geometries.single), closeTo(12, 1e-6));
      final split = buildSectionCaps(
        combineCapShells([
          (BoxGeometry(), Vec3.zero),
          (BoxGeometry(), const Vec3(3, 0, 0)),
        ]),
        Mat4.identity(),
        [plane],
      );
      expect(split.issue, isNull);
      expect(capArea(split.geometries.single), closeTo(2, 1e-6));
    },
  );
  test('larger curved meshes no longer hit the old triangle ceiling', () {
    final result = buildSectionCaps(
      SphereGeometry(widthSegments: 128, heightSegments: 64),
      Mat4.identity(),
      [ClippingPlane(normal: const Vec3(0, 1, 0), offset: .123)],
    );
    expect(result.issue, isNull);
    expect(capArea(result.geometries.single), closeTo(3.09, .03));
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
  test('cap materials reject expanded primitives before attachment', () {
    for (final material in [LineMaterial(), PointsMaterial()]) {
      expect(
        () => SceneSectionPlugin(capMaterial: material),
        throwsArgumentError,
      );
    }
  });
  test(
    'coverage edits remove caps and restore them when full coverage returns',
    () async {
      final source = Mesh(BoxGeometry(), UnlitMaterial());
      final scene = Scene()..add(source);
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
        final original = sections.capMeshes.single;
        source.fragmentCoverage = FragmentCoverage(upper: .5);
        await engine.render(width: 8, height: 8, elapsed: Duration.zero);
        expect(sections.capMeshes, isEmpty);
        expect(original.parent, isNull);
        expect(sections.capIssues[source], SectionCapIssue.topology);
        source.fragmentCoverage = const FragmentCoverage.full();
        await engine.render(width: 8, height: 8, elapsed: Duration.zero);
        expect(sections.capMeshes, hasLength(1));
        expect(sections.capIssues, isEmpty);
      } finally {
        await engine.dispose();
      }
      expect(source.children, isEmpty);
    },
  );
  test(
    'coincident planes produce one cap and zero-thickness slices produce none',
    () {
      final box = BoxGeometry();
      expect(
        buildSectionCaps(box, Mat4.identity(), [cut, cut]).geometries,
        hasLength(1),
      );
      expect(
        buildSectionCaps(box, Mat4.identity(), [cut, cut.flipped]).geometries,
        isEmpty,
      );
    },
  );
  test(
    'instance transforms refresh cap slots without changing source identity',
    () async {
      final source = InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 2);
      source.setTransform(
        1,
        Mat4.compose(const Vec3(2, 0, 0), Quat.identity, Vec3.one),
      );
      final scene = Scene()..add(source);
      final sections = SceneSectionPlugin(capMaterial: UnlitMaterial());
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => _InstanceRenderer(),
        plugins: [sections],
      );
      try {
        sections.setCapTargets([source]);
        sections.setPlanes([ClippingPlane(normal: const Vec3(0, 0, 1))]);
        expect(sections.capMeshes, hasLength(2));
        source.setTransform(
          1,
          Mat4.compose(const Vec3(2, 0, 2), Quat.identity, Vec3.one),
        );
        await engine.render(width: 8, height: 8, elapsed: Duration.zero);
        expect(sections.capMeshes, hasLength(1));
        sections.capsEnabled = false;
        expect(sections.capMeshes, isEmpty);
        sections.capsEnabled = true;
        expect(sections.capMeshes, hasLength(1));
        expect(source.count, 2);
      } finally {
        await engine.dispose();
      }
    },
  );
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

class _InstanceRenderer extends TestRenderer {
  _InstanceRenderer() : super([]);
  @override
  RendererCapabilities get capabilities => _InstanceCapabilities();
}

class _InstanceCapabilities extends RendererCapabilities {
  _InstanceCapabilities()
    : super(
        name: 'instance test',
        features: {
          RenderFeature.indexedMeshes,
          RenderFeature.rgbaReadback,
          RenderFeature.instancing,
        },
        maxDimension: 64,
      );
  @override
  DeviceLimits get limits => DeviceLimits(
    maxTextureDimension2D: 64,
    maxGeometryBytes: 64 * 1024 * 1024,
    maxInstances: 2,
  );
}
