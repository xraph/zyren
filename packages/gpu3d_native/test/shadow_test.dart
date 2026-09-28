import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/shadow_checks.dart';

void main() {
  test(
    'native shadows follow geometry, masks and light edits with bounded caching',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyShadows(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'shared views bound atlas memory and recover after rejection and close',
    () async {
      final backend = await NativeBackend.create();
      final views = [backend, for (var i = 0; i < 4; i++) backend.createView()];
      final scene = Scene()..add(DirectionalLight(shadow: DirectionalShadow()));
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(1, 1),
      );
      try {
        for (final view in views.take(4)) {
          await view.render(frame);
        }
        expect((await backend.shadowStats()).residentBytes, 64 * 1024 * 1024);
        await expectLater(
          views.last.render(frame),
          throwsA(
            isA<SceneException>().having(
              (error) => error.issue.cause.toString(),
              'native admission detail',
              contains('64 MiB'),
            ),
          ),
        );
        expect((await backend.shadowStats()).atlasCount, 4);
        await views[1].close();
        expect((await backend.shadowStats()).atlasCount, 3);
        await views.last.render(frame);
        expect((await backend.shadowStats()).atlasCount, 4);
        await backend.render(frame);
      } finally {
        for (final view in views.reversed) {
          await view.close();
        }
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
