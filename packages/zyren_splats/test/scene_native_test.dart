import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_splats/zyren_splats.dart';

void main() {
  for (final perspective in [false, true]) {
    test(
      'scene Gaussian depth, clipping and transforms (${perspective ? 'perspective' : 'orthographic'})',
      () async {
        final data = GaussianCloudData(
          sourceUri: Uri.parse('memory:scene'),
          sourceVersion: 'v1',
          splats: [
            GaussianSplat(
              mean: Vec3.zero,
              covariance: GaussianCovariance(xx: .12, yy: .05, zz: .03),
              color: const Color3(1, 0, 0),
            ),
          ],
        );
        final plugin = GaussianSplatPlugin(data: data);
        final camera = perspective
            ? PerspectiveCamera(position: const Vec3(0, 0, 3))
            : OrthographicCamera(
                position: const Vec3(0, 0, 3),
                near: .1,
                far: 10,
              );
        final scene = Scene()..background = const Color3(0, 0, 0);
        final plane = Mesh(
          PlaneGeometry(width: 2, height: 2),
          UnlitMaterial(color: const Color3(0, 1, 0)),
        )..position = const Vec3(0, 0, 1);
        final backend = await NativeBackend.create();
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend,
          plugins: [plugin],
        );
        var closed = false;
        plugin.onClose(() => closed = true);
        Future<ImageData> render() async =>
            (await engine.renderFrame(
                      elapsed: Duration.zero,
                      width: 128,
                      height: 128,
                    )
                    as ReadbackOutput)
                .image;
        int channel(ImageData image, int x, int y, int c) =>
            image.pixels[(y * 128 + x) * 4 + c];
        try {
          final first = await render();
          expect(channel(first, 64, 64, 0), greaterThan(220));
          scene.add(plane);
          final occluded = await render();
          expect(channel(occluded, 64, 64, 0), lessThan(5));
          expect(channel(occluded, 64, 64, 1), greaterThan(220));
          plane.position = const Vec3(0, 0, -1);
          final front = await render();
          expect(channel(front, 64, 64, 0), greaterThan(220));
          scene.remove(plane);
          scene.clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
          final clipped = await render();
          expect(channel(clipped, 60, 64, 0), 0);
          expect(channel(clipped, 68, 64, 0), greaterThan(50));
          scene.clippingPlanes = [];
          plugin.object.position = const Vec3(.7, 0, 0);
          final moved = await render();
          expect(
            channel(moved, 64, 64, 0),
            lessThan(channel(first, 64, 64, 0)),
          );
          plugin.object.visible = false;
          final hidden = await render();
          expect(channel(hidden, 64, 64, 0), 0);
          print('Gaussian scene backend: ${backend.capabilities.backend}');
        } finally {
          await engine.dispose();
        }
        expect(closed, isTrue);
        expect(plugin.object.children, isEmpty);
        plugin.object.visible = true;
        plugin.object.position = Vec3.zero;
        final recreated = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: NativeBackend.create,
          plugins: [plugin],
        );
        var closedAgain = false;
        plugin.onClose(() => closedAgain = true);
        try {
          final frame =
              await recreated.renderFrame(
                    elapsed: Duration.zero,
                    width: 128,
                    height: 128,
                  )
                  as ReadbackOutput;
          expect(channel(frame.image, 64, 64, 0), greaterThan(220));
        } finally {
          await recreated.dispose();
        }
        expect(closedAgain, isTrue);
        expect(plugin.object.children, isEmpty);
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
  }
}
