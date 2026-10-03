import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native receipts report executed batches and preserve source identities',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene();
        final geometry = BoxGeometry(width: .2, height: .2, depth: .2);
        final material = UnlitMaterial(color: const Color3(1, 0, 0));
        final meshes = List.generate(
          4,
          (i) => Mesh(geometry, material)..position = Vec3(i * .5 - .75, 0, 0),
        );
        for (final mesh in meshes) {
          scene.add(mesh);
        }
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
        Future<ReadbackOutput> draw() async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(201, 101),
                  ),
                )
                as ReadbackOutput;
        final first = await draw();
        expect(first.stats.drawCalls, 2);
        expect(first.stats.profile!.executedMeshDraws, 1);
        expect(first.stats.profile!.batchedSourceDraws, 4);
        expect(first.stats.profile!.automaticInstanceUploadBytes, 512);
        expect(first.stats.admission!.presentedIdentities.length, 4);
        expect(first.stats.admission!.presentedIdentities.toSet().length, 4);
        final identities = first.stats.admission!.presentedIdentities;
        final warm = await draw();
        expect(warm.stats.profile!.automaticInstanceUploadBytes, 0);
        expect(warm.stats.profile!.drawPlanReuses, 1);
        expect(warm.stats.uploadedBytes, 0);
        expect(warm.stats.admission!.presentedIdentities, identities);
        for (var i = 0; i < meshes.length; i++) {
          meshes[i].renderOrder = i;
        }
        final explicit = await draw();
        expect(explicit.stats.drawCalls, 5);
        expect(explicit.image.pixels, orderedEquals(first.image.pixels));
        expect(explicit.stats.admission!.presentedIdentities, identities);
        for (final mesh in meshes) {
          mesh.renderOrder = 0;
        }
        final temporal =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(201, 101),
                    colorPipeline: ColorPipeline(
                      toneMapping: ToneMapping.linear,
                    ),
                    temporalAA: TemporalAAOptions(),
                  ),
                )
                as ReadbackOutput;
        expect(temporal.stats.profile!.opaqueBatchDraws, 0);
        expect(temporal.stats.profile!.executedMeshDraws, 4);
        expect(temporal.stats.admission!.presentedIdentities, identities);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
