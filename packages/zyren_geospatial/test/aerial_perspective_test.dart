import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

int encoded(double value) =>
    ((value <= .0031308
                    ? value * 12.92
                    : 1.055 * math.pow(value, 1 / 2.4) - .055)
                .clamp(0, 1) *
            255)
        .round();
List<int> center(RenderedFrame image) => image.pixels.sublist(
  ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4,
  ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4 + 4,
);

void main() {
  test('aerial controls preserve defaults and reject invalid albedo', () {
    final defaults = AtmosphereAppearance();
    expect(defaults.transmittance, isTrue);
    expect(defaults.inscatter, isTrue);
    expect(defaults.sunLight, isFalse);
    expect(defaults.skyLight, isFalse);
    expect(defaults.reconstructNormal, isFalse);
    expect(defaults.correctGeometricError, isFalse);
    final edited = defaults.copyWith(
      transmittance: false,
      inscatter: false,
      sunLight: true,
      skyLight: true,
      reconstructNormal: true,
      correctGeometricError: true,
      albedoScale: .6,
    );
    expect(edited.transmittance, isFalse);
    expect(edited.inscatter, isFalse);
    expect(
      edited.sunLight &&
          edited.skyLight &&
          edited.reconstructNormal &&
          edited.correctGeometricError,
      isTrue,
    );
    expect(edited.albedoScale, .6);
    for (final invalid in [-1.0, double.nan, double.infinity, 65505.0]) {
      expect(
        () => AtmosphereAppearance(albedoScale: invalid),
        throwsArgumentError,
      );
    }
    expect(
      () => AerialPerspectiveInputs(lightingMaskChannel: 4),
      throwsArgumentError,
    );
  });

  for (final strategy in DepthStrategy.values) {
    test(
      '$strategy independent extinction and inscatter match runtime reference',
      () async {
        final reference = jsonDecode(
          File(
            'test/fixtures/atmosphere/scattering-balanced.json',
          ).readAsStringSync(),
        );
        final entry = (reference['runtime'] as List).firstWhere(
          (v) => v['input'][3] == 10 && v['input'][1] > 0,
        );
        final p = (entry['input'] as List).cast<num>();
        final date = DateTime.utc(2026, 3, 20, 12);
        final sun = CelestialDirections.at(date).sunECEF;
        final perpendicular = sun.cross(const Vec3(0, 0, 1)).normalized();
        final radial =
            sun * p[2].toDouble() + perpendicular * math.sqrt(1 - p[2] * p[2]);
        final tangent = (sun - radial * p[2].toDouble()).normalized();
        final ray =
            (radial * p[1].toDouble() + tangent * math.sqrt(1 - p[1] * p[1]))
                .normalized();
        final camera = PerspectiveCamera(
          position: radial * (p[0] * 1000).toDouble(),
          near: 1,
          far: 1e8,
          up: sun,
          depthStrategy: strategy,
        );
        camera.target = camera.position + ray * 10000;
        const color = Color3(.2, .3, .4);
        final mesh = Mesh(
          PlaneGeometry(width: 4000, height: 4000),
          UnlitMaterial(color: color),
        )..position = camera.position + ray * (p[3] * 1000).toDouble();
        mesh.lookAt(camera.position);
        final scene = Scene()
          ..renderSettings = RenderSettings(hdr: true)
          ..add(mesh);
        final backend = await NativeBackend.create();
        final plugin = AtmospherePlugin(
          date: date,
          parameters: AtmosphereParameters.legacy(),
          correctAltitude: false,
          appearance: AtmosphereAppearance(sky: false),
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend.createView(),
          plugins: [plugin],
        );
        try {
          for (final ortho in [false, true]) {
            engine.camera = ortho
                ? OrthographicCamera(
                    position: camera.position,
                    target: camera.target,
                    up: camera.up,
                    left: -1000,
                    right: 1000,
                    bottom: -1000,
                    top: 1000,
                    near: 1,
                    far: 1e8,
                    depthStrategy: strategy,
                  )
                : camera;
            for (final trans in [false, true]) {
              for (final scatter in [false, true]) {
                plugin.controller.appearance = AtmosphereAppearance(
                  sky: false,
                  transmittance: trans,
                  inscatter: scatter,
                );
                final pixel = center(
                  await engine.render(
                    elapsed: Duration.zero,
                    width: 33,
                    height: 33,
                  ),
                );
                for (var c = 0; c < 3; c++) {
                  final value =
                      color.toList()[c] *
                          (trans ? entry['transmittance'][c] as num : 1) +
                      (scatter ? entry['radiance'][c] as num : 0);
                  expect(
                    pixel[c],
                    closeTo(encoded(value.toDouble()), 3),
                    reason:
                        'ortho=$ortho trans=$trans scatter=$scatter channel=$c',
                  );
                }
                expect(pixel[3], 255);
              }
            }
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

  test(
    'native normals, masks and premultiplied overlays retain and replace inputs',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final date = DateTime.utc(2026, 3, 20, 12);
      final sun = CelestialDirections.at(date).sunECEF;
      final camera = PerspectiveCamera(
        position: sun * 6361100,
        target: sun * 6360000,
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 1e8,
      );
      final parameters = AtmosphereParameters.legacy().copyWith(
        rayleighScattering: Vec3.zero,
        mieScattering: Vec3.zero,
        mieExtinction: Vec3.zero,
        absorptionExtinction: Vec3.zero,
      );
      const color = Color3(.2, .3, .4);
      final mesh = Mesh(
        PlaneGeometry(width: 4000, height: 4000),
        UnlitMaterial(color: color),
      )..position = sun * 6360100;
      mesh.lookAt(camera.position);
      final scene = Scene()
        ..renderSettings = RenderSettings(hdr: true)
        ..add(mesh);
      final plugin = AtmospherePlugin(
        date: date,
        parameters: parameters,
        correctAltitude: false,
        appearance: AtmosphereAppearance(
          sky: false,
          haze: false,
          sunLight: true,
          reconstructNormal: true,
          albedoScale: .6,
        ),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      Future<RenderedFrame> render([int size = 33]) =>
          engine.render(elapsed: Duration.zero, width: size, height: size);
      Future<GpuResource<Texture>> texture(List<double> rgba) async {
        final value = await owner.resources.createTexture(
          TextureDescriptor(
            width: 1,
            height: 1,
            format: TextureFormat.rgba32Float,
          ),
        );
        await owner.resources.writeTexture(value, Float32List.fromList(rgba));
        return value;
      }

      try {
        final invalid = await owner.resources.createTexture(
          TextureDescriptor(
            width: 1,
            height: 1,
            format: TextureFormat.r32Float,
          ),
        );
        expect(
          () => AerialPerspectiveInputs(normal: invalid, lightingMask: invalid),
          throwsArgumentError,
        );
        expect(
          () =>
              AerialPerspectiveInputs(overlay: invalid, lightingMask: invalid),
          throwsArgumentError,
        );
        expect(
          () => AerialPerspectiveInputs(
            lightingMask: invalid,
            lightingMaskChannel: 1,
          ),
          throwsArgumentError,
        );
        final lit = center(await render());
        final irradiance = parameters.solarIrradiance;
        final conversion = parameters.sunRelativeLuminance;
        for (var c = 0; c < 3; c++) {
          final expected =
              color.toList()[c] *
              .6 /
              math.pi *
              irradiance.storage[c] *
              conversion.storage[c];
          expect(lit[c], closeTo(encoded(expected), 2));
        }
        plugin.controller.appearance = plugin.controller.appearance.copyWith(
          sunLight: false,
          skyLight: true,
        );
        expect(center(await render()).take(3), everyElement(0));
        plugin.controller.appearance = plugin.controller.appearance.copyWith(
          sunLight: true,
          skyLight: false,
          reconstructNormal: false,
        );
        final oct = await texture([0, 0, 1, 1]);
        await plugin.controller.setAerialInputs(
          AerialPerspectiveInputs(
            normal: oct,
            normalEncoding: AerialNormalEncoding.octahedral,
          ),
        );
        expect(center(await render()), lit);
        final worldNormal = await texture([
          (sun.x + 1) * .5,
          (sun.y + 1) * .5,
          (sun.z + 1) * .5,
          1,
        ]);
        await plugin.controller.setAerialInputs(
          AerialPerspectiveInputs(
            normal: worldNormal,
            normalSpace: AerialNormalSpace.world,
          ),
        );
        expect(center(await render()), lit);
        final sentinel = await texture([0, 0, 0, 0]);
        await plugin.controller.setAerialInputs(
          AerialPerspectiveInputs(normal: sentinel),
        );
        expect(center(await render()).take(3), color.toList().map(encoded));
        // Reconstructed normals override the supplied sentinel.
        plugin.controller.appearance = plugin.controller.appearance.copyWith(
          reconstructNormal: true,
        );
        expect(center(await render()), lit);
        plugin.controller.appearance = plugin.controller.appearance.copyWith(
          reconstructNormal: false,
        );
        final normal = await texture([
          .5,
          .5,
          0,
          1,
        ]); // View-space back-facing normal.
        final mask = await texture([0, .25, .75, 1]);
        final overlay = await texture([.05, .1, .15, .5]);
        await plugin.controller.setAerialInputs(
          AerialPerspectiveInputs(normal: normal),
        );
        expect(center(await render()).take(3), everyElement(0));
        final nearPosition = camera.position;
        plugin.controller.appearance = plugin.controller.appearance.copyWith(
          correctGeometricError: true,
        );
        for (final height in [100000.0, 600000.0, 2000000.0]) {
          camera.position = sun * (Ellipsoid.wgs84.maximumRadius + height);
          final actualHeight = Ellipsoid.wgs84.fromEcef(camera.position).height;
          final scale =
              Ellipsoid.wgs84.maximumRadius /
              (math.tan(camera.fieldOfView / 2) * actualHeight);
          final amount = ((scale - 41.5) / (13.8 - 41.5)).clamp(0, 1).toDouble();
          final p = mesh.position, inv = Ellipsoid.wgs84.reciprocalRadiiSquared;
          final sphere = Vec3(
            p.x * inv.x,
            p.y * inv.y,
            p.z * inv.z,
          ).normalized();
          final cosine = ((-sun) * (1 - amount) + sphere * amount)
              .dot(sun)
              .clamp(0, 1);
          final result = center(await render());
          for (var c = 0; c < 3; c++) {
            final expected =
                color.toList()[c] *
                .6 /
                math.pi *
                irradiance.storage[c] *
                conversion.storage[c] *
                cosine;
            expect(
              result[c],
              closeTo(encoded(expected), 3),
              reason: 'height=$height',
            );
          }
        }
        camera.position = nearPosition;
        plugin.controller.appearance = plugin.controller.appearance.copyWith(
          correctGeometricError: false,
        );
        await plugin.controller.setAerialInputs(
          AerialPerspectiveInputs(
            normal: normal,
            lightingMask: mask,
            lightingMaskChannel: 1,
            overlay: overlay,
          ),
        );
        await owner
            .close(); // Plugin retains its own inputs across resize/source replacement.
        for (final size in [33, 41, 33]) {
          final result = center(await render(size));
          for (var c = 0; c < 3; c++) {
            final expected = color.toList()[c] * .75 * .5 + [.05, .1, .15][c];
            expect(result[c], closeTo(encoded(expected), 2));
          }
          expect(result[3], 255);
        }
        final retained = (await backend.resourceStats()).residentBytes;
        await expectLater(
          plugin.controller.setAerialInputs(
            AerialPerspectiveInputs(normal: normal),
          ),
          throwsStateError,
        );
        expect((await backend.resourceStats()).residentBytes, retained);
        // The graph accepts premultiplied inputs and must carry overlay alpha
        // over an empty transparent frame, including after resize.
        scene.remove(mesh);
        final empty = center(await render());
        // Readback is premultiplied sRGB, so encode straight RGB before applying alpha.
        for (var c = 0; c < 3; c++) {
          expect(empty[c], closeTo(encoded([.1, .2, .3][c]) * .5, 1));
        }
        expect(empty[3], closeTo(128, 1));
        scene.add(mesh);
        await plugin.controller.setParameters(parameters);
        expect(
          center(await render())[0],
          closeTo(encoded(.2 * .75 * .5 + .05), 2),
        );
        await plugin.controller.setAerialInputs(AerialPerspectiveInputs());
        expect(center(await render()).take(3), orderedEquals(lit.take(3)));
        expect(
          (await backend.resourceStats()).residentBytes,
          lessThan(retained),
        );
      } finally {
        await owner.close();
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
}
