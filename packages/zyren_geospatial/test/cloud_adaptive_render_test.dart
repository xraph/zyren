import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';
import 'cloud_shadow_test.dart' show constantCloudTextures;
import 'cloud_render_test.dart' show uniformClouds;

void main() {
  test(
    'measured scene pressure changes ray work without target replacement',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      final textures = await constantCloudTextures(owner),
          date = DateTime.utc(2026, 3, 20, 12);
      final sun = CelestialDirections.at(date).sunECEF;
      final cloud = CloudPlugin(
        textures: textures,
        parameters: uniformClouds(1),
        quality: CloudQualityPreset.low,
        maxResolution: 32,
        shadowMapSize: 8,
        animationEnabled: false,
        sceneFrameBudget: CloudSceneFrameBudget(
          target: const Duration(microseconds: 1),
          pressureSamples: 1,
          cooldownSamples: 0,
        ),
      );
      final engine = await SceneEngine.create(
        scene: Scene()..renderSettings = RenderSettings(hdr: true),
        camera: PerspectiveCamera(
          position: sun * 6360100,
          target: sun * 6363000,
          up: const Vec3(0, 0, 1),
          near: 1,
          far: 1e7,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [
          AtmospherePlugin(
            date: date,
            parameters: AtmosphereParameters.legacy(),
            correctAltitude: false,
            maxStarResolution: 16,
          ),
          cloud,
        ],
      );
      final records = <Map<String, Object?>>[];
      try {
        int? bytes;
        bool measured = false;
        for (var i = 0; i < 8; i++) {
          final output = await engine.renderFrame(
            elapsed: Duration(milliseconds: i * 16),
            width: 32,
            height: 32,
          );
          measured |= output.stats.profile?.gpuTimeNs != null;
          final resident = (await backend.resourceStats()).residentBytes;
          bytes ??= resident;
          expect(resident, bytes);
          expect(cloud.controller.quality, CloudQualityPreset.low);
          records.add({
            'profile': output.stats.profile?.toJson(),
            'adaptive': cloud.controller.adaptiveDiagnostics,
            'residentBytes': resident,
          });
        }
        if (measured) {
          expect(cloud.controller.adaptiveDiagnostics['effectiveRayStride'], 8);
          expect(cloud.controller.adaptiveDiagnostics['transitions'], 2);
          expect(
            cloud.controller.adaptiveDiagnostics['presentedHistoryFrames'],
            8,
          );
          expect(
            records.any(
              (r) => (r['adaptive'] as Map)['shadowUpdate'] == 'reused',
            ),
            true,
          );
        } else {
          expect(cloud.controller.adaptiveDiagnostics['effectiveRayStride'], 4);
          expect(cloud.controller.adaptiveDiagnostics['transitions'], 0);
        }
        cloud.controller.setSceneFrameBudget(null);
        await engine.render(
          elapsed: const Duration(milliseconds: 128),
          width: 32,
          height: 32,
        );
        expect(cloud.controller.adaptiveDiagnostics['enabled'], false);
        expect(cloud.controller.adaptiveDiagnostics['effectiveRayStride'], 4);
        expect((await backend.resourceStats()).residentBytes, bytes);
        final evidence = Platform.environment['CLOUD_EVIDENCE_DIR'];
        if (evidence != null) {
          await File(
            '$evidence/adaptive-render.json',
          ).writeAsString(jsonEncode(records));
        }
      } finally {
        await engine.dispose();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}
