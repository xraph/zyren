import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_capture/zyren_capture.dart';
import 'package:planet/ocean/scenes/coast_store.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:planet/ocean/scenes/fog.dart';
import 'package:planet/ocean/scenes/world.dart';

void main() {
  test(
    'native distance fog reduces surface submissions and follows camera motion',
    () async {
      final directory = await Directory.systemTemp.createTemp('ocean-fog-');
      final coast = await OceanLabCoast.open(
        directory,
        allowFixtureGeneration: true,
      );
      final definition = OceanLabSceneDefinition.decode(
        File('assets/ocean/scenes.json').readAsStringSync(),
      ).singleWhere((s) => s.id == 'calm');
      final backend = await NativeBackend.create();
      await backend.configureResourceBudget(768 * 1024 * 1024);
      final counts = <OceanLabFog, int>{};
      final draws = <OceanLabFog, int>{};
      Vec3? physicalPosition;
      try {
        for (final fog in [OceanLabFog.off, OceanLabFog.dense]) {
          final lab = OceanLabWorld(definition, coast, fog: fog);
          final uncull = _Uncull(lab);
          final engine = await SceneEngine.create(
            scene: lab.scene,
            camera: lab.camera,
            backendFactory: () async => backend.createView(),
            plugins: [...lab.plugins, uncull],
          );
          try {
            final output =
                await engine.renderFrame(
                      elapsed: Duration.zero,
                      width: 320,
                      height: 200,
                    )
                    as ReadbackOutput;
            final frame = output.image;
            draws[fog] = output.stats.drawCalls;
            final view = lab.presentation!.view!;
            counts[fog] = view.visiblePatchCount;
            expect(view.visiblePatchCount, greaterThan(0));
            expect(lab.simulationFailure, isNull);
            final sample =
                (await lab.host.registry.find(oceanSampler)!.sampleBatch([
                  OceanQuery(
                    lab.host.worldFrame.toEcef(Vec3.zero),
                    lab.host.clock.instant,
                  ),
                ], OceanQueryPolicy())).single;
            expect(sample.available, isTrue);
            if (physicalPosition != null) {
              expect(sample.value!.positionEcef, physicalPosition);
            }
            physicalPosition = sample.value!.positionEcef;
            stdout.writeln(
              '${fog.name}: ${view.visiblePatchCount}/${view.patchCount} visible patches, ${output.stats.drawCalls} native draws',
            );
            if (fog == OceanLabFog.dense) {
              expect(view.visiblePatchCount, lessThan(view.patchCount));
              // Sky and fully hidden surface converge to the same fog color.
              final sky = frame.pixels.sublist(
                (10 * 320 + 160) * 4,
                (10 * 320 + 160) * 4 + 4,
              );
              expect(sky.take(3), everyElement(greaterThan(50)));
              uncull.enabled = true;
              final unculled =
                  await engine.renderFrame(
                        elapsed: Duration.zero,
                        width: 320,
                        height: 200,
                      )
                      as ReadbackOutput;
              expect(
                unculled.stats.drawCalls,
                greaterThan(output.stats.drawCalls),
              );
              var maxDifference = 0;
              for (var i = 0; i < frame.pixels.length; i++) {
                final delta = (frame.pixels[i] - unculled.image.pixels[i])
                    .abs();
                if (delta > maxDifference) maxDifference = delta;
              }
              expect(
                maxDifference,
                lessThanOrEqualTo(2),
                reason: 'Culling must preserve the fogged image.',
              );
              stdout.writeln(
                'Fogged versus unculled maximum channel difference: $maxDifference/255',
              );
              uncull.enabled = false;
              await engine.render(
                elapsed: Duration.zero,
                width: 320,
                height: 200,
              );
              final originalVisible = view.meshes
                  .map((m) => m.visible)
                  .toList();
              lab.camera.position += const Vec3(1000000, 0, 0);
              lab.camera.target += const Vec3(1000000, 0, 0);
              // This is before the periodic LOD rebuild. Culling still follows the eye.
              await engine.render(
                elapsed: const Duration(milliseconds: 17),
                width: 320,
                height: 200,
              );
              expect(lab.presentation!.view, same(view));
              expect(
                view.meshes.map((m) => m.visible).toList(),
                isNot(originalVisible),
              );
            }
            final capture = Platform.environment['OCEAN_FOG_CAPTURE'];
            if (capture != null) {
              await Directory(capture).create(recursive: true);
              await File(
                '$capture/${fog.name}.png',
              ).writeAsBytes(encodeCapturePng(frame));
            }
          } finally {
            await engine.dispose();
            expect((await backend.resourceStats()).liveAllocations, 0);
            expect((await backend.graphStats()).liveGraphs, 0);
          }
        }
        expect(counts[OceanLabFog.dense], lessThan(counts[OceanLabFog.off]!));
        expect(draws[OceanLabFog.dense], lessThan(draws[OceanLabFog.off]!));
      } finally {
        await backend.close();
        await coast.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

final class _Uncull extends ScenePlugin {
  final OceanLabWorld lab;
  bool enabled = false;
  _Uncull(this.lab);
  @override
  String get id => 'test.uncull';
  @override
  Set<String> get dependencies => {lab.ocean.id};
  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (enabled) {
      for (final mesh in lab.presentation!.view!.meshes) {
        mesh.visible = true;
      }
    }
  }
}
