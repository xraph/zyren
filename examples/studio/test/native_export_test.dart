import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/streaming.dart';

void main() {
  test(
    'native exported scene matches authored scene pixels at the saved camera',
    () async {
      final document = StudioDocument(
        id: 'pixels',
        title: 'Pixels',
        environment: StudioEnvironment(
          background: 0x192938,
          keyIntensity: 2,
          fillIntensity: .4,
        ),
        nodes: [
          StudioNode(
            id: 'box',
            label: 'Box',
            rotation: Quat.axisAngle(const Vec3(0, 1, 0), .4),
            material: StudioMaterial(
              kind: StudioMaterialKind.standard,
              color: 0xa86232,
              metallic: .4,
              roughness: .3,
            ),
          ),
          StudioNode(
            id: 'ground',
            label: 'Ground',
            position: const Vec3(0, -1, 0),
            scale: const Vec3(5, .2, 5),
          ),
        ],
      );
      final authored = StudioScene(document),
          package = ZyrenScenePackage.compile(document);
      final exported = await ZyrenSceneStream.open(
        Uri.parse('asset:/scene.zyren'),
        read: (uri, _, _) async => uri.path.endsWith('.zyren')
            ? package.manifest
            : package.files[uri.path.substring(1)]!,
      );
      await exported.loadAll();
      final backend = await NativeBackend.create();
      try {
        final before =
            await backend.render(
                  FrameSubmission.capture(
                    scene: authored.scene,
                    camera: authored.camera,
                    size: PhysicalSize(128, 128),
                  ),
                )
                as ReadbackOutput;
        final after =
            await backend.render(
                  FrameSubmission.capture(
                    scene: exported.scene,
                    camera: exported.camera,
                    size: PhysicalSize(128, 128),
                  ),
                )
                as ReadbackOutput;
        expect(after.image.pixels, before.image.pixels);
        expect(before.image.pixels.toSet().length, greaterThan(20));
      } finally {
        await backend.close();
        await exported.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
