import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'retained cloud targets follow camera and weather through staging and replacement',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      final textures = await CloudTextures.generate(owner, size: 8);
      final date = DateTime.utc(2026, 3, 20, 12),
          sun = CelestialDirections.at(DateTime.utc(2026, 3, 20, 12)).sunECEF;
      final camera = PerspectiveCamera(
        position: sun * 6360100,
        target: sun * 6363000,
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 1e7,
      );
      final parameters = CloudParameters(
        coverage: .8,
        localWeatherVelocity: (.003, .001),
        shapeVelocity: const Vec3(1, 0, 0),
      );
      CloudPlugin cloud() => CloudPlugin(
        textures: textures.textures,
        parameters: parameters,
        quality: CloudQualityPreset.low,
        maxResolution: 32,
        shadowMapSize: 8,
        appearance: CloudAppearance(hazeDensityScale: 0),
      );
      final subject = cloud(),
          reference = cloud(),
          fail = _FailFrame(),
          controlFail = _FailFrame();
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      Future<SceneEngine> engine(
        Scene scene,
        CloudPlugin layer, {
        bool staged = false,
      }) => SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async =>
            backend.createView()
              ..configureSceneUploadBudget(staged ? 1500 : 64000000),
        plugins: [
          AtmospherePlugin(
            date: date,
            parameters: AtmosphereParameters.legacy(),
            correctAltitude: false,
            maxStarResolution: 16,
            appearance: AtmosphereAppearance(sky: false, haze: false),
          ),
          layer,
          if (staged) fail else controlFail,
        ],
      );
      final actual = await engine(scene, subject, staged: true);
      final control = await engine(
        Scene()..renderSettings = RenderSettings(hdr: true),
        reference,
      );
      var number = 0;
      final evidence = Platform.environment['CLOUD_EVIDENCE_DIR'];
      final records = <Map<String, Object?>>[];
      Future<ReadbackOutput> render(
        SceneEngine engine,
        int n, {
        int size = 33,
      }) async =>
          await engine.renderFrame(
                elapsed: Duration(milliseconds: n * 16),
                width: size,
                height: size,
              )
              as ReadbackOutput;
      void addCandidate(int count) {
        for (var i = 0; i < count; i++) {
          final mesh = Mesh(
            PlaneGeometry(width: .01, height: .01),
            UnlitMaterial(
              colorMap: TextureMap(
                image: TextureImage.rgba(
                  width: 32,
                  height: 32,
                  pixels: Uint8List(32 * 32 * 4),
                ),
              ),
            ),
          );
          mesh.position = sun * 6370000 + const Vec3(0, 0, 100);
          scene.add(mesh);
        }
      }

      Future<void> compare({bool replace = false, int size = 33}) async {
        camera.position += const Vec3(0, 0, .1);
        camera.target += const Vec3(0, 0, .1);
        final output = await render(actual, number, size: size);
        final ready = output.stats.admission!.candidateReady;
        if (replace &&
            ready &&
            reference.controller.quality == CloudQualityPreset.low) {
          await reference.controller.setQualitySettings(
            CloudQualitySettings(
              preset: CloudQualityPreset.medium,
              maxResolution: 24,
              shadowMapSize: 8,
            ),
          );
        }
        final expected = await render(control, number++, size: size);
        var maximum = 0;
        for (var y = size ~/ 2 - 3; y <= size ~/ 2 + 3; y++) {
          for (var x = size ~/ 2 - 3; x <= size ~/ 2 + 3; x++) {
            for (var c = 0; c < 4; c++) {
              final index = (y * size + x) * 4 + c;
              maximum = math.max(
                maximum,
                (output.image.pixels[index] - expected.image.pixels[index])
                    .abs(),
              );
            }
          }
        }
        var fullDifference = 0;
        for (var i = 0; i < output.image.pixels.length; i++) {
          fullDifference = math.max(
            fullDifference,
            (output.image.pixels[i] - expected.image.pixels[i]).abs(),
          );
        }
        records.add({
          'frame': number,
          'width': size,
          'height': size,
          'maxFullDifference': fullDifference,
          'ready': ready,
          'maxCenterDifference': maximum,
          'subject': subject.controller.adaptiveDiagnostics,
          'reference': reference.controller.adaptiveDiagnostics,
        });
        if (evidence != null) {
          await File(
            '$evidence/staged-history.json',
          ).writeAsString(jsonEncode(records));
        }
        expect(fullDifference, lessThanOrEqualTo(2));
        expect(
          maximum,
          lessThanOrEqualTo(2),
          reason:
              'retained graph must use current cloud uniforms and matching history',
        );
        expect(
          subject.controller.adaptiveDiagnostics['presentedHistoryFrames'],
          reference.controller.history.accumulatedFrames,
        );
        if (evidence != null) {
          await File(
            '$evidence/staged-frame-$number.rgba',
          ).writeAsBytes(output.image.pixels);
          await File(
            '$evidence/staged-reference-$number.rgba',
          ).writeAsBytes(expected.image.pixels);
        }
      }

      try {
        for (var i = 0; i < 3; i++) {
          await compare();
        }
        addCandidate(12);
        for (var i = 0; i < 5; i++) {
          await compare();
        }
        expect(
          records.where((r) => r['ready'] == false).length,
          greaterThanOrEqualTo(4),
        );
        await subject.controller.setQualitySettings(
          CloudQualitySettings(
            preset: CloudQualityPreset.medium,
            maxResolution: 24,
            shadowMapSize: 8,
          ),
        );
        for (var i = 0; i < 16; i++) {
          await compare(replace: true);
        }
        expect(records.last['ready'], true);
        expect(subject.controller.quality, CloudQualityPreset.medium);
        fail.fail = true;
        await expectLater(render(actual, number), throwsStateError);
        fail.fail = false;
        controlFail.fail = true;
        await expectLater(render(control, number), throwsStateError);
        controlFail.fail = false;
        await compare(replace: true);
        expect(
          subject.controller.history.reason,
          CloudHistoryReset.failedFrame,
        );
        await compare(replace: true, size: 41);
        camera.target += const Vec3(250, 0, 0);
        await compare(replace: true, size: 41);
        camera.position += (camera.target - camera.position).normalized() * 50;
        await compare(replace: true, size: 41);
        camera.zoom = 1.1;
        await compare(replace: true, size: 41);
        expect(subject.controller.history.reason, CloudHistoryReset.projection);
        if (evidence != null) {
          await File(
            '$evidence/staged-history.json',
          ).writeAsString(jsonEncode(records));
        }
      } finally {
        await actual.dispose();
        await control.dispose();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}

final class _FailFrame extends ScenePlugin {
  bool fail = false;
  @override
  String get id => 'cloud-staging-failure';
  @override
  Set<String> get dependencies => {'clouds'};
  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (fail) throw StateError('intentional frame failure');
  }
}
