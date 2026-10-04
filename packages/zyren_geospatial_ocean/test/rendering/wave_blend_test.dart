import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native quality blend preserves both field layouts and endpoint samples',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final fixture = fixtureSea(resolution: 16);
      final state = OceanSeaState(
        seed: fixture.seed,
        canonicalResolution: 16,
        bands: [
          ...fixture.bands,
          OceanWaveBand(
            patchMetres: 16,
            minWaveNumber: 0,
            maxWaveNumber: 4,
            windSpeed: 4,
            windHeadingRadians: 1,
            amplitude: .1,
          ),
        ],
      );
      try {
        final from = await OceanWaveStream.create(
          owner,
          state: state,
          chartIds: [0],
          resolution: 8,
          bandCount: 1,
        );
        final to = await OceanWaveStream.create(
          owner,
          state: state,
          chartIds: [0],
          resolution: 16,
        );
        final bytes = OceanWaveBlend.estimate(8, 1, 16, 2, 1).bytes;
        final before = (await backend.resourceStats()).liveAllocations;
        await expectLater(
          OceanWaveBlend.create(
            owner,
            from: from,
            to: to,
            maxLogicalBytes: bytes - 1,
          ),
          throwsA(isA<ResourceException>()),
        );
        expect((await backend.resourceStats()).liveAllocations, before);
        await backend.configureResourceBudget(16 * 1024 * 1024);
        final blocker = owner.resources.createChild();
        await blocker.createBuffer(
          BufferDescriptor(
            size:
                16 * 1024 * 1024 -
                (await backend.resourceStats()).residentBytes -
                2000,
            usage: {BufferUsage.copyDestination},
          ),
        );
        final pressured = (await backend.resourceStats()).liveAllocations;
        await expectLater(
          OceanWaveBlend.create(owner, from: from, to: to),
          throwsA(isA<ResourceException>()),
        );
        expect((await backend.resourceStats()).liveAllocations, pressured);
        expect(from.isReady && to.isReady, isTrue);
        await blocker.close();
        await backend.configureResourceBudget(256 * 1024 * 1024);
        final blend = await OceanWaveBlend.create(owner, from: from, to: to);
        final patch = OceanPatchId(face: 0, level: 16, x: 32768, y: 32768);
        Future<OceanWaterMaterial> material(OceanWaveRenderInputs waves) =>
            OceanWaterMaterial.create(
              owner,
              waves: waves,
              patch: patch,
              geometrySpacingMetres: .1,
            );
        final a = await material(from),
            b = await material(to),
            mixed = await material(blend);
        final points = [
          Vec3.zero,
          const Vec3(0, 3.2, -7.1),
          const Vec3(0, 16.7, 5.3),
        ];
        final allocations = (await backend.resourceStats()).liveAllocations;
        for (final seconds in [0.0, .37, 100.0]) {
          await from.update(seconds);
          expect(blend.isReady, isFalse);
          await to.update(seconds);
          for (final fraction in [0.0, .25, .5, 1.0]) {
            await blend.update(fraction);
            expect(mixed.isReady, isTrue);
            for (final footprint in [.1, 3.0, 20.0]) {
              final expectedA = await a.debugSurface(
                points,
                footprintMetres: footprint,
              );
              final expectedB = await b.debugSurface(
                points,
                footprintMetres: footprint,
              );
              final actual = await mixed.debugSurface(
                points,
                footprintMetres: footprint,
              );
              for (var i = 0; i < points.length; i++) {
                expect(
                  actual[i].offsetEcef.distanceTo(
                    expectedA[i].offsetEcef * (1 - fraction) +
                        expectedB[i].offsetEcef * fraction,
                  ),
                  lessThan(2e-6),
                );
                if (fraction == 0 || fraction == 1) {
                  final endpoint = fraction == 0 ? expectedA[i] : expectedB[i];
                  expect(
                    actual[i].normalEcef.distanceTo(endpoint.normalEcef),
                    lessThan(2e-6),
                  );
                  expect(
                    actual[i].unresolvedSlopeVariance,
                    closeTo(endpoint.unresolvedSlopeVariance, 2e-6),
                  );
                }
              }
            }
          }
        }
        expect((await backend.resourceStats()).liveAllocations, allocations);
        final revision = mixed.surfaceRevision;
        await expectLater(blend.update(double.nan), throwsArgumentError);
        expect(mixed.surfaceRevision, revision);
        expect(blend.isReady, isTrue);
        await from.update(101);
        await expectLater(blend.update(.5), throwsStateError);
        await to.update(101);
        await blend.update(.5);
        final pending = blend.update(.75);
        await expectLater(blend.update(1), throwsStateError);
        await pending;
        await blend.close();
        expect(mixed.isReady, isFalse);
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
