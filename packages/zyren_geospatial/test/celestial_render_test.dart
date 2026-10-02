import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

int srgb(double linear) =>
    ((linear <= .0031308
                    ? linear * 12.92
                    : 1.055 * math.pow(linear, 1 / 2.4) - .055)
                .clamp(0, 1) *
            255)
        .round();
Vec3 rotate(Mat4 matrix, Vec3 p) {
  final m = matrix.storage;
  return Vec3(
    m[0] * p.x + m[4] * p.y + m[8] * p.z,
    m[1] * p.x + m[5] * p.y + m[9] * p.z,
    m[2] * p.x + m[6] * p.y + m[10] * p.z,
  );
}

void main() {
  test(
    'native celestial disks, catalogue photometry, occlusion and orthographic exclusion',
    () async {
      final backend = await NativeBackend.create();
      final view = backend.createView();
      final parameters = AtmosphereParameters.webgpu().copyWith(
        rayleighScattering: Vec3.zero,
        mieScattering: Vec3.zero,
        mieExtinction: Vec3.zero,
        absorptionExtinction: Vec3.zero,
      );
      final bytes = Uint8List(20);
      final data = ByteData.sublistView(bytes);
      for (final offset in [0, 10]) {
        data.setInt16(offset, 32767, Endian.little);
        bytes.fillRange(offset + 7, offset + 10, 255);
      }
      final date = DateTime.utc(2026, 4, 2);
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      final camera = PerspectiveCamera(
        near: 1,
        far: 1e8,
        fieldOfView: Angle.degrees(40),
      );
      final moonPixels = Uint8List.fromList([
        255,
        20,
        10,
        255,
        10,
        255,
        20,
        255,
        20,
        10,
        255,
        255,
        180,
        150,
        120,
        255,
      ]);
      final plugin = AtmospherePlugin(
        date: date,
        parameters: parameters,
        correctAltitude: false,
        moonMap: MoonMap(width: 2, height: 2, pixels: moonPixels),
        stars: StarCatalog.fromBytes(bytes),
        appearance: AtmosphereAppearance(
          ground: false,
          sunIntensity: 0,
          moonIntensity: 0,
          starIntensity: 100000,
          starPointSize: 3,
        ),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => view,
        plugins: [plugin],
      );
      Future<RenderedFrame> render() =>
          engine.render(elapsed: Duration.zero, width: 129, height: 129);
      List<int> center(RenderedFrame f) =>
          f.pixels.sublist((64 * 129 + 64) * 4, (64 * 129 + 64) * 4 + 3);
      void aim(Vec3 direction) {
        camera.position = direction * 1e7;
        camera.target = camera.position + direction * 10000;
        camera.up = const Vec3(0, 0, 1);
      }

      try {
        final directions = CelestialDirections.at(date);
        final starDirection = rotate(directions.eciToEcef, const Vec3(1, 0, 0));
        aim(starDirection);
        final stars = await render();
        final solid = math.pow(6 / (129 / math.tan(20 * math.pi / 180)), 2);
        final luminance =
            2 *
            10.8e4 *
            math.pow(10, .8) /
            (4.25e10 * solid) *
            100000 /
            parameters.sunRadianceToLuminance.dot(
              const Vec3(.2126, .7152, .0722),
            );
        for (final channel in center(stars)) {
          expect(channel, closeTo(srgb(luminance), 2));
        }
        final occluder = Mesh(
          SphereGeometry(radius: 100),
          UnlitMaterial(color: const Color3(0, 0, 0)),
        )..position = camera.position + starDirection * 1000;
        scene.add(occluder);
        expect(center(await render()), [0, 0, 0]);
        scene.remove(occluder);
        final glass = Mesh(
          SphereGeometry(radius: 100),
          UnlitMaterial(
            color: const Color3(.2, .3, .4),
            opacity: .5,
            side: MaterialSide.front,
            alphaMode: MaterialAlphaMode.blend,
          ),
        )..position = camera.position + starDirection * 1000;
        scene.add(glass);
        final blended = center(await render());
        for (var c = 0; c < 3; c++) {
          expect(
            blended[c],
            closeTo(srgb([.2, .3, .4][c] * .5 + luminance * .5), 2),
          );
        }
        scene.remove(glass);

        plugin.controller.date = date.add(const Duration(hours: 6));
        expect(center(await render()), [0, 0, 0]);
        plugin.controller.date = date;
        engine.camera = OrthographicCamera(
          position: camera.position,
          target: camera.target,
          up: camera.up,
          left: -100,
          right: 100,
          top: 100,
          bottom: -100,
          near: 1,
          far: 1e8,
        );
        expect(center(await render()), [0, 0, 0]);
        engine.camera = camera;
        aim(directions.sunECEF);
        plugin.controller.appearance = AtmosphereAppearance(
          ground: false,
          sunIntensity: .00001,
          moonIntensity: 0,
          starIntensity: 0,
        );
        camera.fieldOfView = Angle.degrees(2);
        final solar = await render();
        for (var c = 0; c < 3; c++) {
          final value =
              parameters.solarIrradiance.storage[c] *
              parameters.sunRelativeLuminance.storage[c] /
              (math.pi *
                  parameters.sunAngularRadius *
                  parameters.sunAngularRadius) *
              .00001;
          expect(center(solar)[c], closeTo(srgb(value), 2));
        }
        expect(solar.pixels.take(3), everyElement(0));
        aim(directions.moonECEF);
        var observed = CelestialDirections.at(
          date,
          observerECEF: camera.position,
        );
        camera.target = camera.position + observed.moonECEF * 10000;
        plugin.controller.appearance = AtmosphereAppearance(
          ground: false,
          sunIntensity: 0,
          moonIntensity: 10,
          starIntensity: 0,
        );
        final lunar = await render();
        final fixedToEcef = observed.eciToEcef * observed.moonFixedToEci;
        final fixed = rotate(fixedToEcef.inverted(), -observed.moonECEF);
        final u = math.atan2(fixed.y, fixed.x) / (2 * math.pi) + .5;
        final v = math.acos(fixed.z.clamp(-1, 1)) / math.pi;
        final px = u * 2 - .5, py = v * 2 - .5;
        final ix = px.floor(),
            iy = py.floor(),
            fx = px - px.floor(),
            fy = py - py.floor();
        final albedo = List.filled(3, 0.0);
        for (var y = 0; y < 2; y++) {
          for (var x = 0; x < 2; x++) {
            final offset = ((iy + y).clamp(0, 1) * 2 + (ix + x) % 2) * 4;
            for (var c = 0; c < 3; c++) {
              final encoded = moonPixels[offset + c] / 255;
              final linear = encoded <= .04045
                  ? encoded / 12.92
                  : math.pow((encoded + .055) / 1.055, 2.4).toDouble();
              albedo[c] +=
                  linear * (x == 0 ? 1 - fx : fx) * (y == 0 ? 1 - fy : fy);
            }
          }
        }
        final diffuse =
            math.max(0.0, -observed.moonECEF.dot(observed.sunECEF)) /
            math.pi *
            (1 - .5 / 1.33 + .17 / 1.13);
        for (var c = 0; c < 3; c++) {
          final value =
              parameters.solarIrradiance.storage[c] *
              parameters.sunRelativeLuminance.storage[c] *
              2.5e-6 /
              (math.pi * .0045 * .0045) *
              diffuse *
              10 *
              albedo[c];
          expect(center(lunar)[c], closeTo(srgb(value), 2));
        }
        expect(lunar.pixels.take(3), everyElement(0));
        if (Platform.environment['ATMOSPHERE_CAPTURE'] case final prefix?) {
          File('$prefix-sun.rgba').writeAsBytesSync(solar.pixels);
          File('$prefix-moon.rgba').writeAsBytesSync(lunar.pixels);
        }
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
}
