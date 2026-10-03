import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/history.dart';
import 'package:zyren_geospatial/src/clouds/temporal_pass.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  for (final (mode, gradient) in [
    for (final gradient in [false, true])
      for (final mode in [
        CloudTemporalMode.upscale,
        CloudTemporalMode.antialias,
      ])
        (mode, gradient),
  ]) {
    test(
      '${mode.name} resolves Bayer samples, source alpha and disocclusion ${gradient ? 'across a depth gradient' : 'at constant depth'}',
      () async {
        final backend = await NativeBackend.create(),
            owner = GpuScope.fromBackend(backend);
        Future<GpuResource<Texture>> target() => owner.resources.createTexture(
          TextureDescriptor(
            width: 4,
            height: 4,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        final color = await target(),
            data = await target(),
            trans = await target();
        final size = mode == CloudTemporalMode.upscale ? 16 : 4;
        final pass = await CloudTemporalPass.build(
          owner,
          AtmosphereCloudInputs(
            color: color,
            depthVelocityShadow: data,
            transmittance: trans,
          ),
          size,
          size,
        );
        final scene = Scene()
          ..background = const Color3(1, 0, 1)
          ..renderSettings = RenderSettings(hdr: true);
        final r = scene.addEffect(pass.resolve),
            p = scene.addEffect(pass.publish);
        final camera = PerspectiveCamera(),
            history = CloudHistory(),
            settings = CloudTemporalSettings(mode: mode);
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend.createView(),
        );
        Future<void> fill(
          bool initial,
          double depth, {
          bool uniform = false,
        }) async {
          await owner.resources.writeTexture(
            color,
            Float32List.fromList([
              for (var y = 0; y < 4; y++)
                for (var x = 0; x < 4; x++) ...[
                  initial
                      ? .2
                      : uniform || x == 2 && y == 2
                      ? .4
                      : 0,
                  0,
                  0,
                  .5,
                ],
            ]).buffer.asUint8List(),
          );
          await owner.resources.writeTexture(
            data,
            Float32List.fromList([
              for (var i = 0; i < 16; i++) ...[
                gradient && i == 9 ? depth * .25 : depth,
                0,
                0,
                2,
              ],
            ]).buffer.asUint8List(),
          );
          await owner.resources.writeTexture(
            trans,
            Float32List.fromList([
              for (var i = 0; i < 16; i++) ...[.25, 0, 0, 0],
            ]).buffer.asUint8List(),
          );
        }

        Future<ByteData> render(int number) async {
          final frame = history.begin(
            camera: camera,
            aspect: 1,
            width: size,
            height: size,
            number: number,
            elapsed: Duration.zero,
            revision: 0,
            epoch: 0,
            sun: const Vec3(1, 0, 0),
          );
          await pass.prepare(frame, settings);
          r.replace(pass.resolve);
          p.replace(pass.publish);
          final image = await engine.render(
            elapsed: Duration.zero,
            width: size * 3 + 1,
            height: size * 2 + 1,
          );
          expect(image.pixels.sublist(0, 4), [255, 0, 255, 255]);
          expect(image.pixels.sublist(image.pixels.length - 4), [
            255,
            0,
            255,
            255,
          ]);
          history.present(frame, 0);
          return ByteData.sublistView(
            await pass.scope.resources.readTexture(pass.outputs.color),
          );
        }

        double half(ByteData bytes, int x, int y) {
          final h = bytes.getUint16((y * size + x) * 8, Endian.little);
          final exp = (h >> 10) & 31, mantissa = h & 1023;
          return exp == 0
              ? mantissa / 16777216
              : (1 + mantissa / 1024) *
                    (exp < 15 ? 1 / (1 << (15 - exp)) : (1 << (exp - 15)))
                        .toDouble();
        }

        try {
          await fill(true, 1000);
          expect(
            half(await render(0), size ~/ 2, size ~/ 2),
            closeTo(.2, .0002),
          );
          await fill(false, 1000);
          final second = await render(1);
          if (mode == CloudTemporalMode.upscale) {
            expect(half(second, 8, 8), closeTo(.2, .0002));
            expect(half(second, 10, 10), closeTo(.4, .0003));
          } else {
            expect(half(second, 2, 2), closeTo(.22, .0003));
          }
          await fill(false, 10, uniform: mode == CloudTemporalMode.upscale);
          expect(
            half(await render(2), size ~/ 2, size ~/ 2),
            closeTo(.4, .0005),
          );
          if (mode == CloudTemporalMode.upscale) {
            history.invalidate();
            const bayer = [
              0,
              8,
              2,
              10,
              12,
              4,
              14,
              6,
              3,
              11,
              1,
              9,
              15,
              7,
              13,
              5,
            ];
            late ByteData reconstructed;
            for (var phase = 0; phase < 16; phase++) {
              final index = bayer.indexOf(phase);
              await owner.resources.writeTexture(
                color,
                Float32List.fromList([
                  for (var y = 0; y < 4; y++)
                    for (var x = 0; x < 4; x++) ...[
                      (x * 4 + index % 4 + y * 4 + index ~/ 4) / 32,
                      0,
                      0,
                      .5,
                    ],
                ]).buffer.asUint8List(),
              );
              await owner.resources.writeTexture(
                data,
                Float32List.fromList([
                  for (var i = 0; i < 16; i++) ...[
                    phase.isEven ? 1000 : 2000,
                    0,
                    0,
                    2,
                  ],
                ]).buffer.asUint8List(),
              );
              await owner.resources.writeTexture(
                trans,
                Float32List.fromList([
                  for (var y = 0; y < 4; y++)
                    for (var x = 0; x < 4; x++) ...[
                      (x * 4 + index % 4 + y * 4 + index ~/ 4) / 32,
                      0,
                      0,
                      0,
                    ],
                ]).buffer.asUint8List(),
              );
              reconstructed = await render(phase);
            }
            final transmission = ByteData.sublistView(
              await pass.scope.resources.readTexture(
                pass.outputs.transmittance,
              ),
            );
            for (var y = 4; y < 12; y++) {
              for (var x = 4; x < 12; x++) {
                expect(
                  half(reconstructed, x, y),
                  closeTo((x + y) / 32, .001),
                  reason:
                      'Bayer detail at ($x, $y) survives different ray depths',
                );
                expect(
                  transmission.getFloat32((y * size + x) * 4, Endian.little),
                  closeTo((x + y) / 32, .001),
                  reason:
                      'Ground transmission at ($x, $y) recovers each Bayer ray',
                );
              }
            }
          }
        } finally {
          await engine.dispose();
          await owner.close();
          expect((await backend.resourceStats()).residentBytes, 0);
          await backend.close();
        }
      },
    );
  }
}
