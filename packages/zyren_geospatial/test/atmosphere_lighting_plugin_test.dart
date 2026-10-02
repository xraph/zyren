import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'lighting configuration bounds convolution and preserves diffuse defaults',
    () {
      expect(AtmosphereLightingPlugin().skyProbe, isTrue);
      expect(AtmosphereLightingPlugin(environment: true).skyProbe, isFalse);
      for (final invalid in [0, 2048]) {
        expect(
          () => AtmosphereLightingPlugin(captureResolution: invalid),
          throwsArgumentError,
        );
        expect(
          () => AtmosphereLightingPlugin(environmentResolution: invalid),
          throwsArgumentError,
        );
      }
      expect(
        () => AtmosphereLightingPlugin(distanceThreshold: 0),
        throwsArgumentError,
      );
      expect(
        () => AtmosphereLightingPlugin(angularThreshold: double.nan),
        throwsArgumentError,
      );
    },
  );
  final path = Platform.environment['ZYREN_SOURCE_LUTS'];
  test(
    'native sun and sky probe follow date in ECEF and local frames',
    () async {
      final source = PrecomputedAtmosphereSource(
        baseUri: Directory(path!).uri,
        services: AssetServices(resolver: NativeSourceResolver()),
        format: AtmosphereLutFormat.binary,
      );
      final frame = Ellipsoid.wgs84.eastNorthUpFrame(
        Geodetic.degrees(0, 0, 10).toEcef(),
      );
      Vec3 point(Vec3 value) {
        final m = frame.storage;
        return Vec3(
          m[0] * value.x + m[4] * value.y + m[8] * value.z + m[12],
          m[1] * value.x + m[5] * value.y + m[9] * value.z + m[13],
          m[2] * value.x + m[6] * value.y + m[10] * value.z + m[14],
        );
      }

      final pixels = <List<int>>[];
      for (final local in [false, true]) {
        final backend = await NativeBackend.create();
        final sky = AtmospherePlugin(
          date: DateTime.utc(2026, 3, 20, 12),
          source: source,
          worldToEcef: local ? frame : null,
          appearance: AtmosphereAppearance(sky: false, haze: false),
        );
        final lighting = AtmosphereLightingPlugin();
        final scene = Scene()
          ..background = Color3(0, 0, 0)
          ..renderSettings = RenderSettings(hdr: true);
        final plane = Mesh(
          PlaneGeometry(width: 4, height: 4),
          StandardMaterial(baseColor: Color3(.5, .5, .5)),
        );
        if (!local) {
          plane.position = point(Vec3.zero);
          plane.lookAt(point(Vec3(0, 0, 1)));
        }
        scene.add(plane);
        final camera = PerspectiveCamera(
          position: local ? Vec3(0, 0, 5) : point(Vec3(0, 0, 5)),
          target: local ? Vec3.zero : point(Vec3.zero),
          up: local ? Vec3(0, 1, 0) : point(Vec3(0, 1, 0)) - point(Vec3.zero),
          near: .1,
          far: 1e4,
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend.createView(),
          plugins: [sky, lighting],
        );
        final control = lighting.controller;
        try {
          final day = await engine.render(
            elapsed: Duration.zero,
            width: 33,
            height: 33,
          );
          final center = (16 * 33 + 16) * 4;
          pixels.add(day.pixels.sublist(center, center + 3));
          expect(pixels.last.reduce((a, b) => a + b), greaterThan(100));
          final expectedSun = CelestialDirections.at(
            sky.controller.date,
            observerECEF: point(Vec3(0, 0, 5)),
          ).sunECEF;
          final direction = -control.sunLight!.direction;
          final ecefDirection = local
              ? point(direction) - point(Vec3.zero)
              : direction;
          expect(ecefDirection.distanceTo(expectedSun), lessThan(1e-8));
          final actualIrradiance =
              Vec3.array(control.sunLight!.color.toList()) *
              control.sunLight!.intensity;
          expect(
            actualIrradiance.distanceTo(control.sample!.sunIrradiance),
            lessThan(1e-12),
          );
          expect(control.skyProbe!.color.r, greaterThan(0));
          expect(control.tableReadbacks, 2);
          expect(control.environmentGeneration, 0);
          control.sunIntensity = 2;
          sky.controller.date = DateTime.utc(2026, 3, 21, 0);
          final night = await engine.render(
            elapsed: Duration(milliseconds: 16),
            width: 33,
            height: 33,
          );
          expect(control.sunLight!.color.toList(), [0, 0, 0]);
          expect(control.sunIntensity, 2);
          expect(control.tableReadbacks, 2);
          expect(
            night.pixels.sublist(center, center + 3).reduce((a, b) => a + b),
            lessThan(pixels.last.reduce((a, b) => a + b)),
          );
        } finally {
          await engine.dispose();
          expect(control.sunLight!.parent, isNull);
          expect(control.skyProbe!.parent, isNull);
          expect((await backend.resourceStats()).residentBytes, 0);
          await backend.close();
        }
      }
      for (var c = 0; c < 3; c++) {
        expect(pixels[0][c], closeTo(pixels[1][c], 2));
      }
    },
    skip: path == null
        ? 'Set ZYREN_SOURCE_LUTS for native lighting checks.'
        : false,
  );
  test(
    'native sky reflections update by sun, position and LUT without frame readbacks',
    () async {
      final source = PrecomputedAtmosphereSource(
        baseUri: Directory(path!).uri,
        services: AssetServices(resolver: NativeSourceResolver()),
        format: AtmosphereLutFormat.binary,
      );
      final frame = Ellipsoid.wgs84.eastNorthUpFrame(
        Geodetic.degrees(0, 0, 10).toEcef(),
      );
      final atmosphere = AtmospherePlugin(
        date: DateTime.utc(2026, 3, 20, 12),
        source: source,
        worldToEcef: frame,
        appearance: AtmosphereAppearance(sky: false, haze: false),
      );
      final lighting = AtmosphereLightingPlugin(
        sun: false,
        environment: true,
        captureResolution: 32,
        environmentResolution: 16,
        roughnessLevels: 4,
        samples: 64,
        brdfSize: 16,
      );
      final backend = await NativeBackend.create();
      final scene = Scene()
        ..background = Color3(0, 0, 0)
        ..renderSettings = RenderSettings(hdr: true);
      scene.add(
        Mesh(
          SphereGeometry(radius: 1),
          StandardMaterial(metallic: 1, roughness: .25),
        ),
      );
      final camera = PerspectiveCamera(
        position: Vec3(0, -5, 2),
        target: Vec3.zero,
        up: Vec3(0, 0, 1),
        near: .1,
        far: 1e5,
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [atmosphere, lighting],
      );
      try {
        final day = await engine.renderFrame(
          elapsed: Duration.zero,
          width: 65,
          height: 65,
        );
        final center = (32 * 65 + 32) * 4;
        final dayPixel = (day as ReadbackOutput).image.pixels
            .sublist(center, center + 3)
            .reduce((a, b) => a + b);
        expect(dayPixel, greaterThan(25));
        final control = lighting.controller;
        expect(control.environmentGeneration, 1);
        expect(control.tableReadbacks, 2);
        expect(control.skyProbe, isNull);
        final oldMap = scene.environment!;
        final resident = (await backend.resourceStats()).residentBytes;
        camera.target = Vec3(.1, 0, 0);
        final stable = await engine.renderFrame(
          elapsed: Duration(milliseconds: 16),
          width: 65,
          height: 65,
        );
        expect(stable.stats.uploadedBytes, 0);
        expect(control.environmentGeneration, 1);
        expect(control.tableReadbacks, 2);
        expect((await backend.resourceStats()).residentBytes, resident);
        control.skyIntensity = 0;
        final dark = await engine.renderFrame(
          elapsed: Duration(milliseconds: 24),
          width: 65,
          height: 65,
        );
        expect(
          (dark as ReadbackOutput).image.pixels.sublist(center, center + 3),
          [0, 0, 0],
        );
        expect(control.environmentGeneration, 1);
        expect(control.tableReadbacks, 2);
        expect(scene.environment!.intensity, 0);
        control.skyIntensity = 1;
        atmosphere.controller.date = DateTime.utc(2026, 3, 21, 0);
        final night = await engine.renderFrame(
          elapsed: Duration(milliseconds: 32),
          width: 65,
          height: 65,
        );
        final nightPixel = (night as ReadbackOutput).image.pixels
            .sublist(center, center + 3)
            .reduce((a, b) => a + b);
        expect(nightPixel, lessThan(dayPixel));
        expect(control.environmentGeneration, 2);
        expect(oldMap.isClosed, isTrue);
        expect(control.tableReadbacks, 2);
        camera.position = camera.position + Vec3(2000, 0, 0);
        await engine.renderFrame(
          elapsed: Duration(milliseconds: 48),
          width: 65,
          height: 65,
        );
        expect(control.environmentGeneration, 3);
        expect((await backend.resourceStats()).residentBytes, resident);
        await atmosphere.controller.setParameters(
          AtmosphereParameters.legacy(),
        );
        await engine.renderFrame(
          elapsed: Duration(milliseconds: 64),
          width: 65,
          height: 65,
        );
        expect(control.environmentGeneration, 4);
        expect(control.tableReadbacks, 4);
        expect(control.sample, isNotNull);
      } finally {
        await engine.dispose();
        expect(scene.environment, isNull);
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    skip: path == null
        ? 'Set ZYREN_SOURCE_LUTS for native lighting checks.'
        : false,
  );
}
