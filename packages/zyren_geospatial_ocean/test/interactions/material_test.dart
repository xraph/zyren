import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../rendering/surface_capture_test.dart' show half;
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';
import 'package:zyren_geospatial_ocean/src/surface/geometry.dart'
    show buildOceanPatchGeometry;
import 'events_test.dart' show initial;

void main() {
  test(
    'water and its boundary share persistent world-anchored interactions',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final state = fixtureSea(wind: 0);
      final patch = OceanPatchId(face: 4, level: 18, x: 131072, y: 131072);
      final origin = patch.point(.5, .5);
      OceanSurfaceCapture? capture;
      try {
        final waves = await OceanWaveFieldGpu.create(
          owner,
          oceanChartSeaState(state, 4),
        );
        final packed = await OceanWaveRenderData.pack(
          owner,
          state: state,
          charts: {4: await waves.evaluate(0, resolution: 8)},
        );
        final field = await OceanInteractionField.create(
          owner,
          anchorEcef: origin,
          initialTime: initial,
          settings: OceanInteractionSettings(resolution: 32, extentMetres: 16),
        );
        final water = await OceanWaterMaterial.create(
          owner,
          waves: packed,
          patch: patch,
          geometrySpacingMetres: .1,
          interactions: field,
        );
        final plain = await OceanWaterMaterial.create(
          owner,
          waves: packed,
          patch: patch,
          geometrySpacingMetres: .1,
        );
        field.enqueue(
          OceanInteraction(
            id: OceanInteractionId('drop', 0),
            time: initial.withTick(1),
            ecefPosition: origin,
            relativeVelocity: field.east * 2,
            radiusMetres: 3,
            energy: .04,
          ),
        );
        final foam = Float32List(32 * 32 * 4);
        for (var i = 0; i < 32 * 32; i++) {
          foam[i * 4] = 5;
        }
        await field.writeFoamSources(foam);
        await field.step(initial.withTick(1));
        final point = field.east * .37 + field.north * .11;
        final actual = (await water.debugSurface([point])).single;
        final reference = (await plain.debugSurface([point])).single;
        expect(
          (actual.offsetEcef - reference.offsetEcef).length,
          greaterThan(.01),
        );
        expect(actual.foam, greaterThan(0));
        const epsilon = .005;
        final around = await water.debugSurface([
          point - field.east * epsilon,
          point + field.east * epsilon,
          point - field.north * epsilon,
          point + field.north * epsilon,
        ]);
        final de =
            field.east +
            (around[1].offsetEcef - around[0].offsetEcef) / (2 * epsilon);
        final dn =
            field.north +
            (around[3].offsetEcef - around[2].offsetEcef) / (2 * epsilon);
        expect(
          actual.normalEcef.distanceTo(de.cross(dn).normalized()),
          lessThan(5e-5),
        );
        await field.recenter(
          origin + field.east * field.settings.cellMetres * 3,
        );
        final moved = (await water.debugSurface([point])).single;
        expect(actual.offsetEcef.distanceTo(moved.offsetEcef), lessThan(2e-7));
        expect(moved.foam, closeTo(actual.foam, 1e-7));
        final geometry = buildOceanPatchGeometry(
          patch,
          64,
          origin,
          (u, v) =>
              origin +
              field.east * ((u - .5) * 16) +
              field.north * ((v - .5) * 16),
          Ellipsoid.wgs84,
        );
        final mesh = Mesh(geometry, water.material)..position = origin;
        final targetLocal = field.east * .5 + field.north * .25;
        final camera = PerspectiveCamera(
          position: origin + targetLocal + field.up * 5,
          target: origin + targetLocal,
          up: field.north,
          near: .1,
          far: 20,
        );
        final size = PhysicalSize(33, 33);
        capture = await OceanSurfaceCapture.create(
          owner,
          backend,
          draws: [OceanBoundaryDraw(water: water, mesh: mesh)],
          size: size,
        );
        await capture.update(camera);
        capture.checkCurrent(camera, size);
        final retained = await owner.resources.retain(capture.texture);
        final pixels = ByteData.sublistView(
          await owner.resources.readTexture(retained),
        );
        final at = (16 * 33 + 16) * 8;
        final distance =
            half(pixels.getUint16(at, Endian.little)) * 32 +
            half(pixels.getUint16(at + 2, Endian.little));
        final offset = (await water.debugSurface([
          targetLocal,
        ])).single.offsetEcef;
        expect(distance, closeTo(5 - offset.dot(field.up), .006));
        await field.step(initial.withTick(2));
        expect(() => capture!.checkCurrent(camera, size), throwsStateError);
        await capture.update(camera);
        capture.checkCurrent(camera, size);
        await field.close();
        expect(() => capture!.checkCurrent(camera, size), throwsStateError);
      } finally {
        await capture?.close();
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
