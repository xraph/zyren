import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'partial native allocation rollback retains reusable canonical query buffers',
    () async {
      final backend = await NativeBackend.create(),
          scope = GpuScope.fromBackend(backend);
      final gpu = await OceanCanonicalGpu.create(
        scope,
        maxSamples: 8,
        maxModes: 1024,
      );
      final first = OceanCanonicalField(fixtureSea(), maxModes: 64).at(1);
      final larger = OceanCanonicalField(
        OceanSeaState(
          seed: 42,
          canonicalResolution: 32,
          bands: [
            OceanWaveBand(
              patchMetres: 64,
              minWaveNumber: 0,
              maxWaveNumber: 10,
              windSpeed: 12,
              windHeadingRadians: .3,
              amplitude: .02,
            ),
          ],
        ),
        maxModes: 1024,
      ).at(1);
      try {
        final before = await gpu.sample(first, [(1.0, 2.0)]),
            payload = gpu.logicalPayloadBytes;
        final bytes = (await backend.resourceStats()).residentBytes;
        await backend.configureResourceBudget(16 * 1024 * 1024);
        final blocker = scope.resources.createChild();
        await blocker.createBuffer(
          BufferDescriptor(
            size: 16 * 1024 * 1024 - bytes - (1024 * 48 + 16),
            usage: {BufferUsage.copyDestination},
          ),
        );
        final pressured = (await backend.resourceStats()).residentBytes;
        await expectLater(
          gpu.sample(larger, [(1.0, 2.0)]),
          throwsA(isA<ResourceException>()),
        );
        expect(gpu.logicalPayloadBytes, payload);
        expect((await backend.resourceStats()).residentBytes, pressured);
        await blocker.close();
        final retained = await gpu.sample(first, [(1.0, 2.0)]);
        expect(retained.values.first.height, before.values.first.height);
        final cancellation = LoadCancellationSource();
        final pending = gpu.sample(larger, [
          (1.0, 2.0),
        ], cancellation: cancellation);
        cancellation.cancel();
        await expectLater(pending, throwsA(isA<LoadCancelled>()));
        expect(gpu.logicalPayloadBytes, payload);
        expect((await backend.resourceStats()).residentBytes, bytes);
        await gpu.sample(larger, [(1.0, 2.0)]);
        expect(before.values.first.height, retained.values.first.height);
      } finally {
        await gpu.close();
        expect(scope.childCount, 0);
        await scope.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test('logical admission and close drain physical query work', () async {
    final backend = await NativeBackend.create(),
        scope = GpuScope.fromBackend(backend);
    final gpu = await OceanCanonicalGpu.create(
      scope,
      maxSamples: 8,
      maxModes: 4096,
      maxLogicalBytes: 4000,
    );
    try {
      final field = OceanCanonicalField(fixtureSea(), maxModes: 64);
      final snapshot = field.at(0);
      await gpu.sample(snapshot, [(0.0, 0.0)]);
      final larger = OceanCanonicalField(
        fixtureSea(resolution: 32),
        maxModes: 1024,
      ).at(0);
      await expectLater(
        gpu.sample(larger, [(0.0, 0.0)]),
        throwsA(isA<ResourceException>()),
      );
      final pending = gpu.sample(snapshot, [(1.0, 2.0)]);
      final busy = expectLater(gpu.sample(snapshot, [(0.0, 0.0)]), throwsStateError);
      final closing = gpu.close();
      await expectLater(pending, throwsStateError);
      await busy;
      await closing;
      expect(gpu.logicalPayloadBytes, 0);
      await expectLater(gpu.sample(snapshot, [(0.0, 0.0)]), throwsStateError);
    } finally {
      await gpu.close();
      await scope.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
