import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
// ignore: depend_on_referenced_packages
import 'package:zyren_tools/zyren_tools.dart';
import '../../zyren_tools/test/support/cap_fixtures.dart';

void main() {
  for (final depth in DepthStrategy.values) {
    test(
      '$depth instance caps preserve reflected slots and release native geometry',
      () async {
        final backend = await NativeBackend.create();
        final scene = Scene()..background = const Color3(0, 0, 0);
        final source = scene.add(
          InstancedMesh(
            BoxGeometry(),
            UnlitMaterial(
              color: const Color3(1, 0, 0),
              side: MaterialSide.front,
            ),
            count: 2,
          ),
        );
        source.setTransform(
          0,
          Mat4.compose(const Vec3(-.75, 0, 0), Quat.identity, Vec3.one),
        );
        source.setTransform(
          1,
          Mat4.compose(
            const Vec3(.75, 0, 0),
            Quat.identity,
            const Vec3(-1, 1, 1),
          ),
        );
        final sections = SceneSectionPlugin(
          capMaterial: UnlitMaterial(color: const Color3(0, 1, 0)),
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: OrthographicCamera(
            depthStrategy: depth,
            left: -2,
            right: 2,
            top: 2,
            bottom: -2,
            near: .1,
            far: 10,
            position: const Vec3(0, 0, 5),
          ),
          backendFactory: () async => backend,
          plugins: [sections],
        );
        try {
          await engine.render(width: 65, height: 65, elapsed: Duration.zero);
          final baseline = (await backend.resourceStats()).residentBytes;
          sections.setCapTargets([source]);
          sections.setPlanes([ClippingPlane(normal: const Vec3(0, 0, -1))]);
          final frame = await engine.render(
            width: 65,
            height: 65,
            elapsed: Duration.zero,
          );
          List<int> pixel(RenderedFrame frame, int x) =>
              frame.pixels.sublist((32 * 65 + x) * 4, (32 * 65 + x) * 4 + 4);
          expect(pixel(frame, 16), [0, 255, 0, 255]);
          expect(pixel(frame, 48), [0, 255, 0, 255]);
          expect(pixel(frame, 32), [0, 0, 0, 255]);
          expect(
            (await backend.resourceStats()).residentBytes,
            greaterThan(baseline),
          );
          source.setTransform(
            1,
            Mat4.compose(
              const Vec3(.75, 0, 2),
              Quat.identity,
              const Vec3(-1, 1, 1),
            ),
          );
          final moved = await engine.render(
            width: 65,
            height: 65,
            elapsed: Duration.zero,
          );
          expect(pixel(moved, 16), [0, 255, 0, 255]);
          expect(pixel(moved, 48), [0, 0, 0, 255]);
          expect(sections.capMeshes, hasLength(1));
          sections.clear();
          await engine.render(width: 65, height: 65, elapsed: Duration.zero);
          expect((await backend.resourceStats()).residentBytes, baseline);
        } finally {
          await engine.dispose();
        }
        expect(source.children, isEmpty);
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
    for (final cavity in [false, true]) {
      test(
        '$depth native ${cavity ? "cavity" : "concave"} cap retains empty regions',
        () async {
          final scene = Scene()..background = const Color3(0, 0, 0);
          final geometry = cavity
              ? combineCapShells([
                  (BoxGeometry(width: 4, height: 4, depth: 4), Vec3.zero),
                  (BoxGeometry(width: 2, height: 2, depth: 2), Vec3.zero),
                ])
              : concaveCapPrism();
          final source = scene.add(
            Mesh(
              geometry,
              UnlitMaterial(
                color: const Color3(1, 0, 0),
                side: MaterialSide.front,
              ),
            ),
          );
          final sections = SceneSectionPlugin(
            capMaterial: UnlitMaterial(color: const Color3(0, 1, 0)),
          );
          final engine = await SceneEngine.create(
            scene: scene,
            camera: OrthographicCamera(
              depthStrategy: depth,
              left: cavity ? -2 : 0,
              right: 2,
              bottom: cavity ? -2 : 0,
              top: 2,
              near: .1,
              far: 10,
              position: const Vec3(0, 0, 5),
            ),
            rendererFactory: NativeRenderer.create,
            plugins: [sections],
          );
          try {
            sections.setCapTargets([source]);
            sections.setPlanes([ClippingPlane(normal: const Vec3(0, 0, -1))]);
            final frame = await engine.render(
              width: 65,
              height: 65,
              elapsed: Duration.zero,
            );
            List<int> pixel(int x, int y) =>
                frame.pixels.sublist((y * 65 + x) * 4, (y * 65 + x) * 4 + 4);
            expect(pixel(cavity ? 56 : 48, cavity ? 32 : 48), [0, 255, 0, 255]);
            expect(pixel(cavity ? 32 : 48, cavity ? 32 : 16), [0, 0, 0, 255]);
          } finally {
            await engine.dispose();
          }
        },
        skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
      );
    }
  }
}
