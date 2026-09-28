import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  for (final samples in [1, 4]) {
    for (final shared in [false, true]) {
      test('rejected HDR $samples-sample edit preserves scene ownership '
          '(shared=$shared)', () async {
        final backend = await NativeBackend.create();
        final other = shared ? backend.createView() : null;
        final geometry = PlaneGeometry(width: 2, height: 2, dynamic: true);
        final original = Float32List.fromList(geometry.positions);
        final scene = Scene()
          ..background = const Color3(0, 0, 0)
          ..add(Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0))));
        FrameSubmission capture({bool oversized = false}) =>
            FrameSubmission.capture(
              scene: scene,
              camera: PerspectiveCamera(),
              size: oversized
                  ? PhysicalSize(2049, samples == 4 ? 1024 : 4096)
                  : PhysicalSize(31, 31),
              colorPipeline: ColorPipeline(
                toneMapping: ToneMapping.linear,
                sampleCount: samples,
              ),
            );
        List<int> center(FrameOutput output) =>
            (output as ReadbackOutput).image.pixels.sublist(1920, 1924);
        try {
          final old = capture();
          expect(center(await backend.render(old)), [255, 0, 0, 255]);
          if (other != null) await other.render(old);
          final before = await backend.resourceStats();
          geometry.updateAttribute(
            VertexSemantic.position,
            Float32List.fromList([
              for (var i = 0; i < original.length; i++)
                original[i] + (i % 3 == 0 ? 20 : 0),
            ]),
          );
          await expectLater(
            backend.render(capture(oversized: true)),
            throwsA(
              isA<SceneException>().having(
                (e) => e.issue.cause.toString(),
                'cause',
                contains('64 MiB per attachment'),
              ),
            ),
          );
          expect(
            (await backend.resourceStats()).residentBytes,
            before.residentBytes,
          );
          final retry = await backend.render(old);
          expect(center(retry), [255, 0, 0, 255]);
          expect(retry.stats.uploadedBytes, 0);
          if (other != null) {
            expect(center(await other.render(old)), [255, 0, 0, 255]);
          }
          final edit = capture();
          final changed = await backend.render(edit);
          expect(center(changed), [0, 0, 0, 255]);
          expect(changed.stats.uploadedBytes, 96);
          if (other != null) await other.render(edit);
          expect((await backend.resourceStats()).liveAllocations, 1);
        } finally {
          await backend.close();
          await other?.close();
        }
      }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
    }
  }
}
