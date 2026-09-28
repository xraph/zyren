import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'directional cascades and spot shadows track casters, masks, bias and view ownership',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
      final receiver = scene.add(
        Mesh(PlaneGeometry(width: 4, height: 4), StandardMaterial()),
      );
      final blocker = scene.add(
        Mesh(PlaneGeometry(width: .4, height: .4), UnlitMaterial())
          ..position = const Vec3(-.5, 0, 1)
          ..castShadow = true,
      );
      final sun = scene.add(
        DirectionalLight(
          direction: const Vec3(.5, 0, -1),
          shadow: ShadowSettings(
            cascades: 2,
            resolution: 256,
            maxDistance: 10,
            normalBias: 0,
          ),
        ),
      );
      final camera = OrthographicCamera(
        left: -1,
        right: 1,
        top: 1,
        bottom: -1,
        near: .1,
        far: 10,
        position: const Vec3(0, 0, 3),
      );
      Future<int> red() async {
        final output =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(33, 33),
                  ),
                )
                as ReadbackOutput;
        return output.image.pixels[(16 * 33 + 16) * 4];
      }

      try {
        expect(await red(), lessThan(5));
        final cached = await backend.graphStats();
        expect(cached.shadowPasses, 2);
        expect(cached.shadowBytes, greaterThan(0));
        await red();
        expect((await backend.graphStats()).shadowPasses, cached.shadowPasses);
        receiver.receiveShadow = false;
        final lit = await red();
        expect(lit, greaterThan(80));
        expect((await backend.graphStats()).shadowPasses, cached.shadowPasses);
        receiver.receiveShadow = true;
        blocker.castShadow = false;
        expect(await red(), closeTo(lit, 1));
        blocker.castShadow = true;
        blocker.scale = const Vec3(-1, 1, 1);
        blocker.material = UnlitMaterial(side: MaterialSide.front);
        expect(await red(), lessThan(5));
        blocker.material = UnlitMaterial(side: MaterialSide.back);
        expect(await red(), closeTo(lit, 1));
        blocker.material = UnlitMaterial();
        camera.position = const Vec3(0, 0, 7);
        expect(await red(), lessThan(5));
        camera.position = const Vec3(0, 0, 3);
        blocker.material = UnlitMaterial(
          alphaMode: MaterialAlphaMode.mask,
          colorMap: TextureMap(
            image: TextureImage.rgba(
              width: 1,
              height: 1,
              pixels: Uint8List.fromList([255, 255, 255, 0]),
            ),
          ),
        );
        expect(await red(), closeTo(lit, 1));
        blocker.material = UnlitMaterial();
        sun.shadow = ShadowSettings(
          cascades: 2,
          resolution: 256,
          maxDistance: 10,
          bias: 1,
          normalBias: 0,
        );
        expect(await red(), closeTo(lit, 1));
        scene.remove(sun);
        final spot = scene.add(
          SpotLight(
            direction: const Vec3(.5, 0, -1),
            intensity: 5,
            angle: .6,
            shadow: ShadowSettings(
              resolution: 256,
              maxDistance: 10,
              normalBias: 0,
            ),
          )..position = const Vec3(-1, 0, 2),
        );
        expect(await red(), lessThan(5));
        blocker.castShadow = false;
        expect(await red(), greaterThan(70));
        spot.shadow = null;
        await red();
        expect((await backend.graphStats()).shadowBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'shadow atlas budget failure preserves earlier view baselines and cleanup',
    () async {
      final backend = await NativeBackend.create();
      final views = [backend, for (var i = 0; i < 4; i++) backend.createView()];
      final scene = Scene()
        ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
      final sun = scene.add(
        DirectionalLight(
          shadow: ShadowSettings(
            resolution: 1024,
            cascades: 4,
            maxDistance: 10,
          ),
        ),
      );
      scene.add(Mesh(BoxGeometry(), StandardMaterial())..castShadow = true);
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
      Future<void> render(NativeBackend view) async {
        await view.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(16, 16),
          ),
        );
      }

      try {
        for (final view in views.take(4)) {
          await render(view);
        }
        expect((await backend.graphStats()).shadowBytes, 64 * 1024 * 1024);
        await expectLater(render(views[4]), throwsA(isA<SceneException>()));
        expect((await backend.graphStats()).shadowBytes, 64 * 1024 * 1024);
        final extra = scene.add(
          DirectionalLight(
            shadow: ShadowSettings(
              resolution: 1024,
              cascades: 4,
              maxDistance: 10,
            ),
          ),
        );
        await expectLater(render(backend), throwsA(isA<SceneException>()));
        scene.remove(extra);
        await render(backend);
        await views[3].close();
        expect((await backend.graphStats()).shadowBytes, 48 * 1024 * 1024);
        await render(views[4]);
        expect((await backend.graphStats()).shadowBytes, 64 * 1024 * 1024);
        sun.shadow = null;
        for (final view in [views[0], views[1], views[2], views[4]]) {
          await render(view);
        }
        expect((await backend.graphStats()).shadowBytes, 0);
      } finally {
        for (final view in views.reversed) {
          await view.close();
        }
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
