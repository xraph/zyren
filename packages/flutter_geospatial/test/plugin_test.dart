import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:flutter_geospatial/flutter_geospatial.dart';
import 'package:test/test.dart';

class _Renderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities =>
      RendererCapabilities(name: 'test', features: {}, maxDimension: 64);
  @override
  Future<RenderedFrame> render(
    Scene scene,
    PerspectiveCamera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}

void main() {
  test(
    'geospatial registers on the core and orbit uses its configured world',
    () async {
      final geospatial = GeospatialPlugin(ellipsoid: Ellipsoid(10, 10, 8));
      final orbit = GlobeOrbitPlugin(distance: 40, rotating: false);
      // Inputs can arrive while native initialization is pending.
      orbit.focus(Geodetic.degrees(90, 0));
      final camera = PerspectiveCamera();
      final originalPosition = camera.position.clone(),
          originalUp = camera.up.clone();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: camera,
        rendererFactory: () async => _Renderer(),
        plugins: [orbit, geospatial],
      );
      expect(engine.pluginIds, ['geospatial', 'geospatial.orbit']);
      await engine.render(elapsed: Duration.zero, width: 1, height: 1);
      expect(camera.position.x, closeTo(0, 1e-12));
      expect(camera.position.y, closeTo(40, 1e-12));
      expect(camera.up, Vector3(0, 0, 1));
      expect(
        geospatial.reference.toEcef(Geodetic.degrees(0, 0)),
        Vector3(10, 0, 0),
      );
      orbit.setDistance(1);
      expect(orbit.distance, 10.5);
      orbit.setDistance(1000);
      expect(orbit.distance, 200);
      orbit.rotateBy(720, 900);
      expect(orbit.latitudeDegrees, 85);
      orbit.reset();
      expect(orbit.distance, 40);
      expect(orbit.latitudeDegrees, 22);
      await engine.dispose();
      expect(camera.position, originalPosition);
      expect(camera.up, originalUp);
    },
  );

  test('orbit rejects a missing geospatial plugin and invalid input', () async {
    await expectLater(
      SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => _Renderer(),
        plugins: [GlobeOrbitPlugin()],
      ),
      throwsArgumentError,
    );
    final orbit = GlobeOrbitPlugin();
    expect(() => orbit.zoom(0), throwsArgumentError);
    expect(() => orbit.rotateBy(double.nan, 0), throwsArgumentError);
    expect(() => GlobeOrbitPlugin(distance: -1), throwsArgumentError);
  });

  test(
    'independent world plugins never share services or camera state',
    () async {
      final earth = GeospatialPlugin(),
          moon = GeospatialPlugin(
            ellipsoid: Ellipsoid(1737400, 1737400, 1737400),
          );
      final earthOrbit = GlobeOrbitPlugin(), moonOrbit = GlobeOrbitPlugin();
      final earthCamera = PerspectiveCamera(), moonCamera = PerspectiveCamera();
      final first = await SceneEngine.create(
        scene: Scene(),
        camera: earthCamera,
        rendererFactory: () async => _Renderer(),
        plugins: [earth, earthOrbit],
      );
      final second = await SceneEngine.create(
        scene: Scene(),
        camera: moonCamera,
        rendererFactory: () async => _Renderer(),
        plugins: [moon, moonOrbit],
      );
      earthOrbit.setDistance(1);
      moonOrbit.setDistance(1);
      expect(earthOrbit.distance, greaterThan(moonOrbit.distance * 3));
      moonOrbit.rotating = false;
      await second.render(elapsed: Duration.zero, width: 1, height: 1);
      final before = moonCamera.position.clone();
      await first.dispose();
      await second.render(
        elapsed: const Duration(seconds: 2),
        width: 1,
        height: 1,
      );
      expect(moonCamera.position, before);
      await second.dispose();
    },
  );
}
