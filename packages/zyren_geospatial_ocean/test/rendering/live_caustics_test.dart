import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'caustic updates reuse resources and reject stale or busy wave inputs',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      try {
        final waves = await OceanWaveStream.create(
          scope,
          state: fixtureSea(resolution: 16),
          chartIds: [4],
          resolution: 16,
        );
        final patch = OceanPatchId(face: 4, level: 16, x: 32768, y: 32768);
        final water = await OceanWaterMaterial.create(
          scope,
          waves: waves,
          patch: patch,
          geometrySpacingMetres: .1,
          lighting: OceanLighting(
            sunDirectionEcef: patch.point(.5, .5).normalized(),
          ),
        );
        final caustics = (await OceanCaustics.create(
          scope,
          water: water,
          settings: OceanUnderwaterSettings(causticResolution: 16),
          extentMetres: 32,
          depthMetres: 2,
        ))!;
        final read = scope.createChild();
        final texture = await read.resources.retain(caustics.texture);
        final first = await read.resources.readTexture(texture);
        final count = (await backend.resourceStats()).liveAllocations;
        expect(caustics.isCurrent, isTrue);
        for (var tick = 1; tick <= 100; tick++) {
          final pending = waves.update(tick / 60);
          expect(caustics.isCurrent, isFalse);
          await expectLater(caustics.update(), throwsStateError);
          await pending;
          expect(caustics.isCurrent, isFalse);
          await caustics.update();
          expect(caustics.isCurrent, isTrue);
        }
        expect(caustics.seconds, 100 / 60);
        expect(caustics.lastStats!.passes, 4);
        expect(caustics.lastStats!.dispatches, 3);
        expect(await read.resources.readTexture(texture), isNot(first));
        expect((await backend.resourceStats()).liveAllocations, count);
        final snapshot = (await OceanCaustics.create(
          scope,
          water: water,
          settings: OceanUnderwaterSettings(causticResolution: 16),
          extentMetres: 32,
          depthMetres: 2,
        ))!;
        final other = await read.resources.retain(snapshot.texture);
        expect(
          await read.resources.readTexture(texture),
          await read.resources.readTexture(other),
        );
        final updating = caustics.update();
        await expectLater(caustics.update(), throwsStateError);
        final closing = caustics.close();
        await updating;
        await closing;
        expect(caustics.isCurrent, isFalse);
        await expectLater(caustics.update(), throwsStateError);
      } finally {
        await scope.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
