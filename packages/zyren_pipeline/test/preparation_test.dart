import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_pipeline/preparation.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import '../example/preparation_fixture.dart';

final executable = File(
  'packages/zyren_pipeline/native/target/debug/zyren_pipeline_prepare',
).absolute.path;
void main() {
  final enabled = Platform.environment['RUN_PIPELINE_PREPARATION'] == '1';
  group(
    'pinned native preparation',
    () {
      late PipelinePreparer preparer;
      setUp(() {
        preparer = PipelinePreparer(executable: executable);
      });
      test(
        'lossless ordering preserves triangle and feature identities',
        () async {
          final snapshot = grid().capture();
          final ids = List.generate(snapshot.primitiveCount, (i) => 'face:$i');
          final result = await preparer.mesh(
            geometry: snapshot,
            sourceId: 'part:grid',
            triangleSourceIds: ids,
          );
          expect(result.geometry.indices, hasLength(snapshot.indices.length));
          expect(result.geometry.attributes, snapshot.attributes);
          expect(
            result.sourceTriangles!.toSet(),
            hasLength(snapshot.primitiveCount),
          );
          for (var i = 0; i < result.sourceTriangles!.length; i++) {
            expect(
              result.triangleSourceIds![i],
              ids[result.sourceTriangles![i]],
            );
          }
          expect(
            result.cacheAcmrAfter,
            lessThanOrEqualTo(result.cacheAcmrBefore),
          );
          expect(result.absoluteError, 0);
          expect(result.outputIndexBytes, result.inputIndexBytes);
        },
      );
      test(
        'planar LOD reduces triangles within its object-space error bound',
        () async {
          final snapshot = grid().capture();
          final levels = await preparer.lods(
            geometry: snapshot,
            sourceId: 'part:grid',
            ratios: [.5, .25],
            maxError: .001,
          );
          for (final result in levels) {
            expect(
              result.geometry.indices.length,
              lessThan(snapshot.indices.length),
            );
            expect(result.absoluteError, lessThanOrEqualTo(.001));
            expect(result.geometry.attributes, snapshot.attributes);
            expect(result.sourceId, 'part:grid');
            expect(result.sourceTriangles, isNull);
            final positions = snapshot.positions;
            for (final vertex in result.geometry.indices) {
              expect(positions[vertex * 3 + 2], 0);
            }
          }
          expect(
            levels.last.outputIndexBytes,
            lessThanOrEqualTo(levels.first.outputIndexBytes),
          );
        },
      );
      test(
        'deformation and face identity protection keep full topology',
        () async {
          final snapshot = grid(deform: true).capture();
          final result = await preparer.mesh(
            geometry: snapshot,
            sourceId: 'rig',
            ratio: .25,
            maxError: 1,
          );
          expect(result.protectionReason, 'deformation-preserved');
          expect(result.geometry.indices.length, snapshot.indices.length);
          expect(result.geometry.morphTargets, snapshot.morphTargets);
          expect(result.geometry.attributes, snapshot.attributes);
          final rigid = grid().capture();
          final protected = await preparer.mesh(
            geometry: rigid,
            sourceId: 'cad',
            ratio: .25,
            maxError: 1,
            triangleSourceIds: List.filled(rigid.primitiveCount, 'feature:1'),
          );
          expect(protected.protectionReason, 'face-identities-preserved');
          expect(protected.geometry.indices.length, rigid.indices.length);
        },
      );
      test(
        'Basis profiles preserve transfer, alpha endpoints and authored mip count',
        () async {
          for (final profile in PipelineTextureProfile.values) {
            for (final srgb in [true, false]) {
              final result = await preparer.texture(
                rgba: checkerPixels(),
                width: 16,
                height: 16,
                srgb: srgb,
                decoder: const NativeTextureDecoder(),
                profile: profile,
              );
              expect(result.decoded.descriptor.format.isSrgb, srgb);
              expect(result.decoded.levels, hasLength(5));
              final pixels = result.decoded.levels.first;
              expect(pixels[(2 * 16 + 2) * 4 + 3], lessThanOrEqualTo(2));
              expect(pixels[(12 * 16 + 12) * 4 + 3], greaterThanOrEqualTo(253));
              expect(pixels[(12 * 16 + 2) * 4], greaterThan(240));
              expect(result.ktx2, isNotEmpty);
            }
          }
        },
      );
      test(
        'encoding is reproducible and each native block target can decode',
        () async {
          Future<PipelinePreparedTexture> encode(
            TextureTranscodeTarget target,
          ) => preparer.texture(
            rgba: checkerPixels(),
            width: 16,
            height: 16,
            srgb: true,
            decoder: NativeTextureDecoder(target: target),
          );
          final first = await encode(TextureTranscodeTarget.rgba8);
          for (final target in TextureTranscodeTarget.values) {
            final result = await encode(target);
            expect(result.ktx2, first.ktx2);
            expect(
              result.decoded.descriptor.format.isCompressed,
              target != TextureTranscodeTarget.rgba8,
            );
          }
        },
      );
      test(
        'budgets, cancellation and worker timeout drain active jobs',
        () async {
          final snapshot = grid().capture();
          final cancelled = PipelineCancellation()..cancel();
          await expectLater(
            preparer.mesh(
              geometry: snapshot,
              sourceId: 'grid',
              cancellation: cancelled,
            ),
            throwsA(isA<LoadCancelled>()),
          );
          await expectLater(
            PipelinePreparer(
              executable: executable,
              maxOutputBytes: 10,
            ).mesh(geometry: snapshot, sourceId: 'grid'),
            throwsFormatException,
          );
          final slow = PipelinePreparer(
            executable: executable,
            timeout: const Duration(microseconds: 1),
          );
          await expectLater(
            slow.texture(
              rgba: Uint8List(256 * 256 * 4),
              width: 256,
              height: 256,
              srgb: true,
              decoder: const NativeTextureDecoder(),
            ),
            throwsA(isA<Exception>()),
          );
          expect(slow.activeJobs, 0);
          final token = PipelineCancellation();
          final running = preparer.texture(
            rgba: Uint8List(512 * 512 * 4),
            width: 512,
            height: 512,
            srgb: true,
            decoder: const NativeTextureDecoder(),
            cancellation: token,
          );
          final checked = expectLater(running, throwsA(isA<LoadCancelled>()));
          await Future<void>.delayed(const Duration(milliseconds: 5));
          token.cancel();
          await checked;
          expect(preparer.activeJobs, 0);
        },
      );
    },
    skip: !enabled
        ? 'Set RUN_PIPELINE_PREPARATION=1 after building the pinned worker.'
        : false,
  );
}
