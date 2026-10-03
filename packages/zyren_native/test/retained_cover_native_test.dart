import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'retained group reprojects a previously culled mesh during staging',
    () async {
      final backend = await NativeBackend.create();
      backend.configureSceneUploadBudget(100);
      final scene = Scene()..background = const Color3(0, 0, 0);
      final group = scene.add(PublicationGroup());
      Mesh box(double x, Color3 color) =>
          Mesh(BoxGeometry(), UnlitMaterial(color: color))
            ..position = Vec3(x, 0, 0);
      final left = box(0, const Color3(1, 0, 0)),
          right = box(4, const Color3(1, 1, 0));
      group.stage([left, right]);
      final camera = PerspectiveCamera();
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(32, 32),
      );
      Future<ReadbackOutput> frame() async =>
          await backend.render(capture()) as ReadbackOutput;
      try {
        while (!(await frame()).stats.admission!.candidateReady) {}
        group.publish([left, right]);
        expect((await frame()).stats.drawCalls, 1);
        final nextLeft = box(0, const Color3(0, 0, 1)),
            nextRight = box(4, const Color3(0, 1, 0));
        group.stage([nextLeft, nextRight]);
        camera.position = const Vec3(4, 0, 5);
        camera.target = const Vec3(4, 0, 0);
        final staged = await frame();
        expect(staged.stats.admission!.candidateReady, isFalse);
        const center = (16 * 32 + 16) * 4;
        expect(staged.image.pixels.sublist(center, center + 4), [
          255,
          255,
          0,
          255,
        ]);
        final raycaster = Raycaster();
        RaycastSnapshot pick() => raycaster.captureFromCamera(
          scene,
          camera,
          const ViewportPoint(16, 16),
          logicalWidth: 32,
          logicalHeight: 32,
        );
        final frozen = pick();
        expect(frozen.intersectFirst()!.object, same(right));
        expect(
          staged.stats.drawCalls,
          2,
          reason: 'transient retained cover relaxes stale CPU frustum flags',
        );
        var published = await frame();
        for (
          var i = 0;
          i < 8 && !published.stats.admission!.candidateReady;
          i++
        ) {
          published = await frame();
        }
        expect(published.stats.admission!.candidateReady, isTrue);
        group.publish([nextLeft, nextRight]);
        expect(published.image.pixels.sublist(center, center + 4), [
          0,
          255,
          0,
          255,
        ]);
        expect(
          published.stats.drawCalls,
          1,
          reason: 'ordinary CPU culling resumes after publication',
        );
        expect(pick().intersectFirst()!.object, same(nextRight));
        expect(frozen.intersectFirst()!.object, same(right));
        group.stage([]);
        group.publish([]);
        await frame();
        expect((await backend.resourceStats()).residentBytes, 0);
        print(
          'Metal retained pan: yellow published mesh appears at the new camera during staging; green replacement publishes; draws 1 -> 2 -> 1; cleanup 0 bytes.',
        );
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
