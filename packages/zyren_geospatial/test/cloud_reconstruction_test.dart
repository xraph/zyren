import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/temporal_pass.dart';
import 'package:zyren_geospatial/src/clouds/history.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  for (final stride in [4, 8]) {
    test(
      'stride $stride reconstructs exposed rays without blocks or old silhouettes',
      () async {
        const size = 32, rawSize = 8;
        final backend = await NativeBackend.create();
        final owner = GpuScope.fromBackend(backend);
        Future<GpuResource<Texture>> target() => owner.resources.createTexture(
          TextureDescriptor(
            width: rawSize,
            height: rawSize,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        final color = await target(),
            data = await target(),
            trans = await target();
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
        final scene = Scene()..renderSettings = RenderSettings(hdr: true);
        // These handles never change, including all frames of a retained graph.
        scene.addEffect(pass.resolve);
        scene.addEffect(pass.publish);
        final camera = PerspectiveCamera(), history = CloudHistory();
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend.createView(),
        );
        final settings = CloudTemporalSettings();
        final evidence = Platform.environment['CLOUD_EVIDENCE_DIR'];
        final metrics = <String, Object?>{
          'stride': stride,
          'width': size,
          'height': size,
        };
        const bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
        var number = 0;
        Future<List<double>> render({
          bool reverse = false,
          bool impulse = false,
          bool edge = false,
          bool background = false,
          bool exposed = false,
        }) async {
          final index = bayer.indexOf(number % 16);
          final jx = index % 4 * stride / 4, jy = index ~/ 4 * stride / 4;
          await owner.resources.writeTexture(
            color,
            Float32List.fromList([
              for (var y = 0; y < rawSize; y++)
                for (var x = 0; x < rawSize; x++) ...[
                  impulse
                      ? (x == 1 && y == 1 ? 1 : 0)
                      : edge
                      ? (x * stride + jx < 16 && !background ? .9 : 0)
                      : reverse
                      ? 1 - (x * stride + jx + y * stride + jy) / 64
                      : (x * stride + jx + y * stride + jy) / 64,
                  0,
                  0,
                  edge ? (x * stride + jx < 16 && !background ? 1 : 0) : .5,
                ],
            ]).buffer.asUint8List(),
          );
          await owner.resources.writeTexture(
            data,
            Float32List.fromList([
              for (var y = 0; y < rawSize; y++)
                for (var x = 0; x < rawSize; x++) ...[
                  edge && x * stride + jx < 16 && !background ? 10 : 1000,
                  exposed ? 2 : 0,
                  0,
                  0,
                ],
            ]).buffer.asUint8List(),
          );
          await owner.resources.writeTexture(
            trans,
            Float32List.fromList([
              for (var i = 0; i < rawSize * rawSize; i++) ...[1, 0, 0, 0],
            ]).buffer.asUint8List(),
          );
          final frame = history.begin(
            camera: camera,
            aspect: 1,
            width: size,
            height: size,
            number: number++,
            elapsed: Duration.zero,
            revision: 0,
            epoch: 0,
            sun: const Vec3(1, 0, 0),
          );
          await pass.prepare(frame, settings, rayStride: stride);
          await engine.render(
            elapsed: Duration.zero,
            width: size,
            height: size,
          );
          history.present(frame, 0);
          final bytes = ByteData.sublistView(
            await pass.scope.resources.readTexture(pass.outputs.color),
          );
          return [
            for (var i = 0; i < size * size; i++)
              half(bytes.getUint16(i * 8, Endian.little)),
          ];
        }

        Future<void> save(String name, List<double> pixels) async {
          if (evidence == null) return;
          final base = '$evidence/stride-$stride-$name';
          await File('$base.json').writeAsString(jsonEncode(pixels));
          await File('$base.ppm').writeAsBytes([
            ...ascii.encode('P6\n$size $size\n255\n'),
            for (final value in pixels)
              ...List.filled(3, (value.clamp(0, 1) * 255).round()),
          ]);
        }

        double error(List<double> pixels, {bool reverse = false}) {
          var maximum = 0.0;
          for (var y = 8; y < 24; y++) {
            for (var x = 8; x < 24; x++) {
              final expected = reverse ? 1 - (x + y) / 64 : (x + y) / 64;
              maximum = math.max(
                maximum,
                (pixels[y * size + x] - expected).abs(),
              );
            }
          }
          return maximum;
        }

        try {
          final bytes = (await backend.resourceStats()).residentBytes;
          final first = await render();
          metrics['invalidHistoryMaxError'] = error(first);
          expect(error(first), lessThan(.001));
          await save('invalid-history', first);
          final exposed = await render(reverse: true, exposed: true);
          metrics['exposedMaxError'] = error(exposed, reverse: true);
          expect(error(exposed, reverse: true), lessThan(.001));
          await save('exposed', exposed);
          history.invalidate();
          late List<double> converged;
          for (var phase = 0; phase < 16; phase++) {
            converged = await render();
          }
          metrics['convergedMaxError'] = error(converged);
          expect(error(converged), lessThan(.001));
          await save('converged', converged);
          history.invalidate();
          await render(edge: true);
          final cleared = await render(edge: true, background: true);
          metrics['clearedSilhouetteMaximum'] = cleared.reduce(math.max);
          expect(cleared.reduce(math.max), lessThan(.001));
          await save('cleared-silhouette', cleared);
          history.invalidate();
          final edge = await render(edge: true);
          for (var y = 0; y < size; y++) {
            expect(
              edge[y * size + 24],
              0,
              reason: 'foreground must not bleed across sky',
            );
          }
          await save('foreground-edge', edge);
          history.invalidate();
          number = 0;
          final impulse = await render(impulse: true);
          for (var x = 0; x <= stride * 2; x++) {
            final expected = 1 - (x - stride).abs() / stride;
            expect(impulse[stride * size + x], closeTo(expected, .001));
          }
          await save('impulse', impulse);
          metrics['impulseFilter'] = 'bilinear tent, fine detail reduced';

          expect((await backend.resourceStats()).residentBytes, bytes);
          if (evidence != null) {
            await File(
              '$evidence/stride-$stride-metrics.json',
            ).writeAsString(jsonEncode(metrics));
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

double half(int bits) {
  final exponent = (bits >> 10) & 31, mantissa = bits & 1023;
  final magnitude = exponent == 0
      ? mantissa / 16777216
      : (1 + mantissa / 1024) * math.pow(2, exponent - 15);
  return (bits & 32768) == 0 ? magnitude.toDouble() : -magnitude.toDouble();
}
