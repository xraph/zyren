import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test('budgets preserve a balanced closed cover and report unmet error', () {
    final camera = PerspectiveCamera(
      position: const Vec3(6379137, 0, 0),
      target: const Vec3(6378137, 0, 0),
      up: const Vec3(0, 0, 1),
      near: .1,
      far: 2e7,
    );
    final settings = OceanLodSettings(
      maxScreenError: 2,
      maxPatches: 96,
      maxVertices: 96 * 81,
      segments: 8,
    );
    final selector = OceanSurfaceSelector(
      ellipsoid: Ellipsoid.wgs84,
      settings: settings,
    );
    final selection = selector.select(
      camera,
      const ViewportMetrics(800, 600),
      displacementBoundMetres: 10,
    );
    expect(OceanPatchCoverage(selection.allPatches).complete, isTrue);
    expect(selection.allPatches.length, lessThanOrEqualTo(96));
    expect(selection.vertexCount, lessThanOrEqualTo(96 * 81));
    expect(selection.budgetLimited, isTrue);
    expect(selection.patches, isNotEmpty);
    for (final pair in selection.neighbourEdges) {
      expect(
        (pair.first.patch.level - pair.second.patch.level).abs(),
        lessThanOrEqualTo(1),
      );
    }
    camera.position = const Vec3(6379137, 0, .001);
    final stable = selector.select(
      camera,
      const ViewportMetrics(800, 600),
      displacementBoundMetres: 10,
    );
    expect(stable.allPatches.toSet(), selection.allPatches.toSet());
  });
  test(
    'distant and orthographic cameras retain coverage without forced refinement',
    () {
      for (final camera in [
        PerspectiveCamera(
          position: const Vec3(1e9, 0, 0),
          up: const Vec3(0, 0, 1),
          far: 2e9,
        ),
        OrthographicCamera(
          position: const Vec3(2e7, 0, 0),
          up: const Vec3(0, 0, 1),
          verticalSize: 3e7,
          far: 4e7,
        ),
      ]) {
        final selected = selectOceanSurface(
          camera,
          const ViewportMetrics(800, 600),
          Ellipsoid.wgs84,
          OceanLodSettings(
            maxScreenError: 100,
            maxPatches: 96,
            maxVertices: 96 * 81,
            segments: 8,
          ),
          displacementBoundMetres: 0,
        );
        expect(OceanPatchCoverage(selected.allPatches).complete, isTrue);
        expect(selected.budgetLimited, isFalse);
      }
    },
  );
}
