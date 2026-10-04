import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean/src/surface/geometry.dart'
    show interpolateOceanGrid;
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native displaced stitched edges agree during opposite LOD transitions',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea();
      final ellipsoid = Ellipsoid(32, 32, 32);
      final roots = [
        for (var f = 0; f < 6; f++) OceanPatchId(face: f, level: 0, x: 0, y: 0),
      ];
      final a = OceanSurfaceGeometry(
        [...roots.skip(1), ...roots[0].children],
        ellipsoid: ellipsoid,
        segments: 8,
        maxVertices: 10000,
      );
      final b = OceanSurfaceGeometry(
        [roots[0], ...roots.skip(2), ...roots[1].children],
        ellipsoid: ellipsoid,
        segments: 8,
        maxVertices: 10000,
      );
      final morph = OceanSurfaceMorph(a, b, maxVertices: 10000);
      final controls = OceanWaterGeometry.fromMorph(morph);
      final scene = Scene();
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 80),
        near: 1,
        far: 200,
      );
      Future<ReadbackOutput> draw() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(96, 96),
                  colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
                ),
              )
              as ReadbackOutput;
      try {
        final source = <int, OceanFieldSnapshot>{};
        for (var id = 0; id < 6; id++) {
          final field = await OceanWaveFieldGpu.create(
            scope,
            oceanChartSeaState(state, id),
          );
          source[id] = await field.evaluate(2.5, resolution: 8);
        }
        final waves = await OceanWaveRenderData.pack(
          scope,
          state: state,
          charts: source,
        );
        final materials = <OceanPatchId, OceanWaterMaterial>{},
            meshes = <OceanPatchId, Mesh>{};
        for (final control in controls.patches) {
          final material = await OceanWaterMaterial.create(
            scope,
            waves: waves,
            patch: control.geometry.id,
            ellipsoid: ellipsoid,
            geometrySpacingMetres: 8,
            controls: control,
            lighting: OceanLighting(
              sunIrradiance: Vec3.zero,
              skyRadiance: const Vec3(0, .1, 1),
              groundRadiance: const Vec3(0, .1, 1),
            ),
            reflections: OceanReflectionSettings(
              mode: OceanReflectionMode.environment,
            ),
          );
          materials[control.geometry.id] = material;
          meshes[control.geometry.id] = scene.add(
            material.createMesh(control.geometry),
          );
        }
        final topology = OceanPatchNeighbours(
          meshes.keys,
          ellipsoid: ellipsoid,
        );
        var maximum = 0.0;
        for (final fraction in [0.0, .5, 1.0]) {
          final offsets = <OceanPatchId, List<Vec3>>{};
          for (final entry in materials.entries) {
            meshes[entry.key]!.morphWeights = [fraction];
            offsets[entry.key] = await entry.value.debugStencilOffsets(
              fraction,
            );
          }
          Vec3 point(OceanPatchId id, double u, double v) {
            final mesh = meshes[id]!;
            return interpolateOceanGrid(8, u, v, (i, j) {
              final vertex = j * 9 + i;
              return mesh.vertexPosition(vertex) +
                  mesh.position +
                  offsets[id]![vertex];
            });
          }

          for (final edge in topology.sharedEdges) {
            for (var i = 0; i <= 32; i++) {
              final t = i / 32;
              final u = oceanEdgeUv(
                edge.first.side,
                edge.first.start + (edge.first.end - edge.first.start) * t,
              );
              final v = oceanEdgeUv(
                edge.second.side,
                edge.second.start +
                    (edge.second.end - edge.second.start) * (1 - t),
              );
              final gap = point(
                edge.first.patch,
                u.u,
                u.v,
              ).distanceTo(point(edge.second.patch, v.u, v.v));
              maximum = math.max(maximum, gap);
              expect(gap, lessThan(3e-5));
            }
          }
          final image = (await draw()).image.pixels;
          expect(image[(48 * 96 + 48) * 4 + 2], greaterThan(20));
        }
        // Device comparison includes float32 local geometry and filtered fields.
        print('Maximum native displaced shared-edge gap: $maximum m');
        for (final mesh in meshes.values) {
          scene.remove(mesh);
        }
        for (final material in materials.values) {
          await material.close();
        }
        await waves.close();
      } finally {
        for (final child in scene.children.toList()) {
          scene.remove(child);
        }
        await scope.close();
        await draw();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
