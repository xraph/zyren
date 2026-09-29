import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_native/surfaces.dart';
import 'package:zyren_native/src/surface_bindings.g.dart' as abi;
import 'package:test/test.dart';

class _UnknownSurface implements SurfaceKey {}

void main() {
  test(
    'backend preserves a captured scene and never silently falls back from a surface',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final mesh = Mesh(
          BoxGeometry(),
          UnlitMaterial(color: const Color3(1, 0, 0)),
        );
        scene.add(mesh);
        final camera = PerspectiveCamera();
        final frame = FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: PhysicalSize(63, 47),
        );
        mesh.visible = false;
        final output = await backend.render(frame);
        expect(output, isA<ReadbackOutput>());
        final readback = output as ReadbackOutput;
        final center = (23 * 63 + 31) * 4;
        expect(readback.image.pixels.sublist(center, center + 4), [
          255,
          0,
          0,
          255,
        ]);
        expect(readback.stats.readbackBytes, 63 * 47 * 4);
        expect(readback.stats.triangles, 12);
        expect(readback.stats.gpuTime, isNull);
        expect(
          backend.capabilities.supports(RenderFeature.sharedTexture),
          isFalse,
        );
        await expectLater(
          backend.openSurface(PhysicalSize(8, 8)),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.code,
              'code',
              SceneIssueCodes.presentationUnavailable,
            ),
          ),
        );
        await expectLater(
          backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(8, 8),
              target: SurfaceTarget(_UnknownSurface(), 1),
            ),
          ),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.code,
              'code',
              'presentationUnavailable',
            ),
          ),
        );
        final empty =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(63, 47),
                  ),
                )
                as ReadbackOutput;
        expect(empty.image.pixels.sublist(center, center + 4), [0, 0, 0, 255]);
      } finally {
        await backend.close();
      }
      await backend.close();
      await expectLater(
        backend.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: PerspectiveCamera(),
            size: PhysicalSize(1, 1),
          ),
        ),
        throwsA(
          isA<SceneException>().having((e) => e.issue.code, 'code', 'disposed'),
        ),
      );
    },
    skip:
        Platform.environment['RUN_NATIVE_GPU'] != '1' &&
        !const bool.fromEnvironment('RUN_NATIVE_GPU'),
  );
  test(
    'close tolerates a revoked surface whose registry slot was reused',
    () async {
      final backend = await NativeBackend.create(
        experimentalAppleSurfaces: true,
      );
      final native = NativeSurfaces();
      final surface = await backend.openSurface(PhysicalSize(63, 47));
      native.close(surface);
      final replacement = native.reserve(width: 63, height: 47);
      try {
        expect(replacement.key, isNot(surface.key));
        await backend.close();
        await backend.close();
        expect(native.read(replacement.key).state, NativeSurfaceState.creating);
      } finally {
        native.close(replacement);
        await backend.close();
      }
    },
    skip: !Platform.isMacOS || Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'experimental surface output carries native receipts and stale epochs defer',
    () async {
      final backend = await NativeBackend.create(
        experimentalAppleSurfaces: true,
      );
      final native = NativeSurfaces();
      final surface = await backend.openSurface(PhysicalSize(63, 47));
      FrameSubmission submission(int epoch) => FrameSubmission.capture(
        scene: Scene(),
        camera: PerspectiveCamera(),
        size: PhysicalSize(63, 47),
        target: SurfaceTarget(surface.key, epoch),
      );
      try {
        final first = await backend.render(submission(surface.epoch));
        final capture = await backend.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: PerspectiveCamera(),
            size: PhysicalSize(63, 47),
          ),
        );
        final next = await backend.render(submission(surface.epoch));
        expect(
          [first.stats.frameId, capture.stats.frameId, next.stats.frameId],
          [1, 2, 3],
        );
        for (var i = 0; i < 12; i++) {
          final output = await backend.render(submission(surface.epoch));
          expect(output, isA<PresentedOutput>());
          expect(output.stats.readbackBytes, 0);
          expect(output.stats.residentBytes, greaterThan(0));
        }
        final suspended = native.suspend(surface, suspended: true);
        await expectLater(
          backend.render(submission(surface.epoch)),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.code,
              'code',
              SceneIssueCodes.frameDeferred,
            ),
          ),
        );
        final resumed = native.suspend(suspended, suspended: false);
        expect(
          (await backend.render(submission(resumed.epoch))).stats.surfaceEpoch,
          resumed.epoch,
        );
      } finally {
        await backend.close();
      }
    },
    skip: !Platform.isMacOS || Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test('discarded surface frame invalidates Dart geometry residency', () async {
    final backend = await NativeBackend.create(experimentalAppleSurfaces: true);
    final native = NativeSurfaces();
    final surface = await backend.openSurface(PhysicalSize(63, 47));
    final a = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
    final b = Scene();
    final other = BoxGeometry();
    for (var i = 0; i < 1000; i++) {
      b.add(Mesh(other, UnlitMaterial()));
    }
    FrameSubmission submission(Scene scene, int epoch) =>
        FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(63, 47),
          target: SurfaceTarget(surface.key, epoch),
        );
    try {
      await backend.render(submission(a, surface.epoch));
      final before = abi.fg2_apple_live_buffers();
      final drawing = backend.render(submission(b, surface.epoch));
      final clock = Stopwatch()..start();
      while (abi.fg2_apple_live_buffers() <= before &&
          clock.elapsed < const Duration(seconds: 5)) {}
      expect(
        abi.fg2_apple_live_buffers(),
        greaterThan(before),
        reason:
            'Observe the actual producer allocation before revoking its epoch.',
      );
      final suspended = native.suspend(surface, suspended: true);
      await expectLater(
        drawing,
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.frameDeferred,
          ),
        ),
      );
      final resumed = native.suspend(suspended, suspended: false);
      expect(
        await backend.render(submission(a, resumed.epoch)),
        isA<PresentedOutput>(),
      );
    } finally {
      await backend.close();
    }
  }, skip: !Platform.isMacOS || Platform.environment['RUN_NATIVE_GPU'] != '1');
}
