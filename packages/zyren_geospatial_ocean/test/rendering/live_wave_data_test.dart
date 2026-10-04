import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'live wave packing reuses native resources and updates existing material bindings',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final state = fixtureSea(resolution: 16);
      final patch = OceanPatchId(face: 0, level: 16, x: 32768, y: 32768);
      try {
        final live = await OceanWaveStream.create(
          owner,
          state: state,
          chartIds: [0],
          resolution: 16,
          seconds: 0,
        );
        final water = await OceanWaterMaterial.create(
          owner,
          waves: live,
          patch: patch,
          geometrySpacingMetres: .1,
        );
        final texture = live.textures[0], revision = water.surfaceRevision;
        final first = (await water.debugSurface([Vec3.zero])).single;
        final allocations = (await backend.resourceStats()).liveAllocations;
        for (var tick = 1; tick <= 100; tick++) {
          await live.update(tick / 60);
        }
        final last = (await water.debugSurface([Vec3.zero])).single;
        expect(last.offsetEcef.distanceTo(first.offsetEcef), greaterThan(1e-4));
        expect(identical(texture, live.textures[0]), isTrue);
        expect(water.seconds, 100 / 60);
        expect(water.surfaceRevision, greaterThan(revision));
        expect(live.lastDispatches, 16);
        expect((await backend.resourceStats()).liveAllocations, allocations);
        final source = await OceanWaveFieldGpu.create(
          owner,
          oceanChartSeaState(state, 0),
        );
        final snapshot = await source.evaluate(100 / 60, resolution: 16);
        final packed = await OceanWaveRenderData.pack(
          owner,
          state: state,
          charts: {0: snapshot},
        );
        for (var level = 0; level <= 4; level++) {
          expect(
            await live.debugRead(0, level: level),
            await packed.debugRead(0, level: level),
          );
        }
        final pending = live.update(2);
        expect(water.isReady, isFalse);
        await expectLater(live.update(3), throwsStateError);
        await pending;
        expect(water.isReady, isTrue);
        final stable = live.seconds;
        await expectLater(live.update(double.nan), throwsArgumentError);
        expect(live.seconds, stable);
        expect(live.isReady, isTrue);
        await live.close();
        expect(water.isReady, isFalse);
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'live wave admission counts all charts and failed native candidates release',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final state = fixtureSea(resolution: 32);
      try {
        final bytes = OceanWaveStream.estimateBytes(16, 1, 2);
        await expectLater(
          OceanWaveStream.create(
            owner,
            state: state,
            chartIds: [0, 4],
            resolution: 16,
            maxLogicalBytes: bytes - 1,
          ),
          throwsA(isA<ResourceException>()),
        );
        expect(owner.childCount, 0);
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.configureResourceBudget(16 * 1024 * 1024);
        final blocker = owner.resources.createChild();
        await blocker.createBuffer(
          BufferDescriptor(
            size: 16 * 1024 * 1024 - 20000,
            usage: {BufferUsage.copyDestination},
          ),
        );
        final before = (await backend.resourceStats()).liveAllocations;
        await expectLater(
          OceanWaveStream.create(
            owner,
            state: state,
            chartIds: [0],
            resolution: 32,
          ),
          throwsA(isA<ResourceException>()),
        );
        expect((await backend.resourceStats()).liveAllocations, before);
        expect(owner.childCount, 0);
        await blocker.close();
        final live = await OceanWaveStream.create(
          owner,
          state: state,
          chartIds: [0, 4],
          resolution: 16,
        );
        expect(live.logicalPayloadBytes, bytes);
        final pending = live.update(1);
        final closing = live.close();
        await pending;
        await closing;
        expect(live.isReady, isFalse);
        await expectLater(live.update(2), throwsStateError);
      } finally {
        await owner.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
