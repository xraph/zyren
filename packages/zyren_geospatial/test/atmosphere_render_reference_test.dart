import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'composited sky and reconstructed scene depth match the original runtime fixtures',
    () async {
      final reference =
          jsonDecode(
                File(
                  'test/fixtures/atmosphere/scattering-balanced.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final backend = await NativeBackend.create();
      final view = backend.createView();
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      final date = DateTime.utc(2026, 3, 20, 12);
      final plugin = AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        appearance: AtmosphereAppearance(
          ground: false,
          sunIntensity: 0,
          moonIntensity: 0,
          starIntensity: 0,
        ),
      );
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 6360010),
        near: 100,
        far: 1e8,
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => view,
        plugins: [plugin],
      );
      try {
        final sun = CelestialDirections.at(date).sunECEF;
        final perpendicular = sun.cross(const Vec3(0, 0, 1)).normalized();
        var number = 0;
        for (final raw in reference['runtime'] as List) {
          final entry = raw as Map<String, dynamic>;
          final p = (entry['input'] as List).cast<num>();
          final radius = p[0].toDouble(),
              mu = p[1].toDouble(),
              mus = p[2].toDouble(),
              path = p[3].toDouble();
          final radial = sun * mus + perpendicular * math.sqrt(1 - mus * mus);
          final tangent = mus.abs() == 1
              ? perpendicular
              : (sun - radial * mus).normalized();
          final ray = (radial * mu + tangent * math.sqrt(1 - mu * mu))
              .normalized();
          camera.position = radial * (radius * 1000);
          camera.target = camera.position + ray * 10000;
          camera.up = ray.cross(sun).length2 < 1e-10
              ? const Vec3(0, 0, 1)
              : sun;
          Mesh? mesh;
          const color = Color3(.2, .3, .4);
          if (path >= 0) {
            mesh = Mesh(
              SphereGeometry(radius: 1000),
              UnlitMaterial(color: color),
            );
            mesh.position = camera.position + ray * (path * 1000 + 1000);
            scene.add(mesh);
          }
          final frame = await engine.render(
            elapsed: Duration.zero,
            width: 33,
            height: 33,
          );
          final center = (16 * 33 + 16) * 4;
          for (var c = 0; c < 3; c++) {
            final linear =
                (entry['radiance'][c] as num).toDouble() +
                (path >= 0
                    ? color.toList()[c] * (entry['transmittance'][c] as num)
                    : 0);
            final encoded = linear <= .0031308
                ? linear * 12.92
                : 1.055 * math.pow(linear, 1 / 2.4) - .055;
            expect(
              frame.pixels[center + c],
              closeTo((encoded.clamp(0, 1) * 255).round(), 3),
              reason: 'fixture $number channel $c',
            );
          }
          engine.camera = OrthographicCamera(
            position: camera.position,
            target: camera.target,
            up: camera.up,
            left: -1000,
            right: 1000,
            bottom: -1000,
            top: 1000,
            near: 100,
            far: 1e8,
          );
          final ortho = await engine.render(
            elapsed: Duration.zero,
            width: 33,
            height: 33,
          );
          for (var c = 0; c < 3; c++) {
            expect(
              ortho.pixels[center + c],
              closeTo(frame.pixels[center + c], 3),
              reason: 'orthographic fixture $number',
            );
          }
          engine.camera = camera;
          if (mesh != null) scene.remove(mesh);
          if (Platform.environment['ATMOSPHERE_CAPTURE'] case final prefix?) {
            final capture = await engine.render(
              elapsed: Duration.zero,
              width: 513,
              height: 257,
            );
            File('$prefix-$number.rgba').writeAsBytesSync(capture.pixels);
          }
          number++;
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
