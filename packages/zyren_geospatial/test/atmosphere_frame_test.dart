import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

Vec3 point(Mat4 matrix, Vec3 p) {
  final m = matrix.storage;
  return Vec3(
    m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
    m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
    m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
  );
}

void main() {
  test(
    'rigid local metres and ECEF render the same corrected atmosphere',
    () async {
      final backend = await NativeBackend.create();
      final engines = <SceneEngine>[];
      final origin = Geodetic.degrees(14, 43, 2000).toEcef();
      final frame = Ellipsoid.wgs84.eastNorthUpFrame(origin);
      final base = point(frame, const Vec3(0, 0, 0)),
          target = point(frame, const Vec3(10000, 10000, 2000));
      final up = point(frame, const Vec3(0, 0, 1)) - base;
      final pictures = <RenderedFrame>[];
      try {
        for (final local in [false, true]) {
          final scene = Scene()
            ..renderSettings = RenderSettings(
              hdr: true,
              toneMapping: ToneMapping.aces,
              exposure: 3,
            );
          final camera = PerspectiveCamera(
            position: local ? Vec3.zero : base,
            target: local ? const Vec3(10000, 10000, 2000) : target,
            up: local ? const Vec3(0, 0, 1) : up,
            near: 1,
            far: 1e8,
          );
          final plugin = AtmospherePlugin(
            date: DateTime.utc(2026, 3, 20, 12),
            worldToEcef: local ? frame : null,
            appearance: AtmosphereAppearance(
              starIntensity: 0,
              sunIntensity: 0,
              moonIntensity: 0,
            ),
          );
          final engine = await SceneEngine.create(
            scene: scene,
            camera: camera,
            backendFactory: () async => backend.createView(),
            plugins: [plugin],
          );
          engines.add(engine);
          pictures.add(
            await engine.render(elapsed: Duration.zero, width: 65, height: 49),
          );
        }
        for (var i = 0; i < pictures[0].pixels.length; i++) {
          expect(
            pictures[0].pixels[i],
            closeTo(pictures[1].pixels[i], 2),
            reason: 'channel $i',
          );
        }
      } finally {
        for (final engine in engines) {
          await engine.dispose();
        }
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
}
