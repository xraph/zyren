import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native surface-to-orbit route renders closed stitched morphs',
    () async {
      final backend = await NativeBackend.create();
      final output = Platform.environment['OCEAN_CAPTURE_DIR'];
      if (output != null) Directory(output).createSync(recursive: true);
      const width = 480, height = 320, segments = 8;
      final selector = OceanSurfaceSelector(
        settings: OceanLodSettings(
          maxScreenError: 4,
          maxPatches: 144,
          maxVertices: 144 * 81,
          segments: segments,
        ),
      );
      OceanSurfaceGeometry? previous;
      final report = <Map<String, Object>>[];
      var maximumEdgeGap = 0.0;
      try {
        for (var frame = 0; frame < 48; frame++) {
          final t = frame / 47,
              altitude = math.exp(math.log(100) + t * math.log(2e7 / 100));
          final lon = t * math.pi * 2,
              lat = math.sin(t * math.pi * 2) * math.pi / 2;
          final target = Ellipsoid.wgs84.toEcef(Geodetic(lon, lat));
          final normal = Ellipsoid.wgs84.surfaceNormal(target);
          final camera = PerspectiveCamera(
            position: target + normal * altitude,
            target: target,
            up: normal.z.abs() > .99
                ? const Vec3(1, 0, 0)
                : const Vec3(0, 0, 1),
            near: math.max(.1, altitude * .01),
            far: altitude + 2 * Ellipsoid.wgs84.maximumRadius,
          );
          final selected = selector.select(
            camera,
            const ViewportMetrics(width * 1.0, height * 1.0),
            displacementBoundMetres: 10,
          );
          final next = OceanSurfaceGeometry(
            selected.allPatches,
            segments: segments,
            maxVertices: 144 * 81,
          );
          final morph = OceanSurfaceMorph(
            previous ?? next,
            next,
            maxVertices: 288 * 81,
          );
          final fractions = (frame % 8 == 0 || frame == 47)
              ? [0.0, .5, 1.0]
              : [1.0];
          for (final fraction in fractions) {
            final scene = Scene()..background = const Color3(0, 0, 0);
            final meshes = <OceanPatchId, Mesh>{};
            for (final patch in morph.patches) {
              meshes[patch.id] = scene.add(
                Mesh(
                    patch.geometry,
                    UnlitMaterial(color: const Color3(.015, .15, .32)),
                  )
                  ..position = patch.origin
                  ..morphWeights = [fraction],
              );
            }
            final topology = OceanPatchNeighbours(meshes.keys);
            Vec3 vertexAt(OceanPatchId id, double u, double v) {
              final mesh = meshes[id]!,
                  x = u * segments,
                  y = v * segments,
                  i = x.floor().clamp(0, segments - 1),
                  j = y.floor().clamp(0, segments - 1),
                  tx = x - i,
                  ty = y - j;
              Vec3 p(int x, int y) =>
                  mesh.vertexPosition(y * (segments + 1) + x) + mesh.position;
              return tx >= ty
                  ? p(i, j) * (1 - tx) +
                        p(i + 1, j) * (tx - ty) +
                        p(i + 1, j + 1) * ty
                  : p(i, j) * (1 - ty) +
                        p(i + 1, j + 1) * tx +
                        p(i, j + 1) * (ty - tx);
            }

            for (final edge in topology.sharedEdges) {
              for (var i = 0; i <= segments * 2; i++) {
                final t = i / (segments * 2),
                    a = oceanEdgeUv(edge.first.side, t),
                    b = oceanEdgeUv(
                      edge.second.side,
                      edge.second.start +
                          (edge.second.end - edge.second.start) * (1 - t),
                    );
                final p = camera.projectPoint(
                      vertexAt(edge.first.patch, a.u, a.v),
                      width / height,
                    ),
                    q = camera.projectPoint(
                      vertexAt(edge.second.patch, b.u, b.v),
                      width / height,
                    );
                if (p.z >= 0 &&
                    p.z <= 1 &&
                    p.x.abs() < 1 &&
                    p.y.abs() < 1 &&
                    q.z >= 0 &&
                    q.z <= 1) {
                  final gap = math.sqrt(
                    math.pow((p.x - q.x) * width / 2, 2) +
                        math.pow((p.y - q.y) * height / 2, 2),
                  );
                  maximumEdgeGap = math.max(maximumEdgeGap, gap);
                }
              }
            }
            final filled =
                await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(width, height),
                      ),
                    )
                    as ReadbackOutput;
            final center = (height ~/ 2 * width + width ~/ 2) * 4;
            expect(
              filled.image.pixels[center + 2],
              greaterThan(20),
              reason: 'route frame $frame fraction $fraction',
            );
            if (output != null && (frame % 8 == 0 || frame == 47)) {
              for (final entry in meshes.entries) {
                final points = <Vec3>[], mesh = entry.value;
                Vec3 linePoint(int index) {
                  final p = mesh.vertexPosition(index);
                  return p +
                      Ellipsoid.wgs84.surfaceNormal(p + mesh.position) *
                          (altitude * .001);
                }

                for (var j = 0; j <= segments; j++) {
                  for (var i = 0; i < segments; i++) {
                    points.addAll([
                      linePoint(j * (segments + 1) + i),
                      linePoint(j * (segments + 1) + i + 1),
                    ]);
                    points.addAll([
                      linePoint(i * (segments + 1) + j),
                      linePoint((i + 1) * (segments + 1) + j),
                    ]);
                  }
                }
                scene.add(
                  Line(
                    LineGeometry.segments(points: points),
                    LineMaterial(
                      color: const Color3(.2, .7, .85),
                      width: 1.25,
                      depthTest: true,
                    ),
                  )..position = mesh.position,
                );
              }
              final wire =
                  await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(width, height),
                        ),
                      )
                      as ReadbackOutput;
              final pixels = wire.image.pixels,
                  rgb = Uint8List(width * height * 3);
              for (var p = 0; p < width * height; p++) {
                rgb.setRange(p * 3, p * 3 + 3, pixels, p * 4);
              }
              File(
                '$output/route-${frame.toString().padLeft(2, '0')}-${(fraction * 100).round()}.ppm',
              ).writeAsBytesSync([
                ...ascii.encode('P6\n$width $height\n255\n'),
                ...rgb,
              ]);
            }
          }
          report.add({
            'frame': frame,
            'altitudeMetres': altitude,
            'patches': selected.allPatches.length,
            'visiblePatches': selected.patches.length,
            'vertices': selected.vertexCount,
            'transitionVertices': morph.vertexCount,
            'maximumCurvatureErrorPixels': selected.maximumScreenError,
            'budgetLimited': selected.budgetLimited,
          });
          previous = next;
        }
        expect(maximumEdgeGap, lessThan(.25));
        if (output != null) {
          File('$output/route.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'backend': 'native macOS',
              'width': width,
              'height': height,
              'maximumFloat32EdgeGapPixels': maximumEdgeGap,
              'waveDisplacementRendered': false,
              'frames': report,
            }),
          );
        }
        print(
          '48 native route frames, maximum float32 mesh edge gap $maximumEdgeGap physical pixels',
        );
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
