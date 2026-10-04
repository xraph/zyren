import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import 'events_test.dart' show initial;

void main() {
  test(
    'native ripples rest, propagate symmetrically and dissipate without reallocating',
    () async {
      final backend = await NativeBackend.create(),
          scope = GpuScope.fromBackend(backend);
      try {
        final field = await OceanInteractionField.create(
          scope,
          anchorEcef: const Vec3(6378137, 0, 0),
          initialTime: initial,
          settings: OceanInteractionSettings(
            resolution: 32,
            extentMetres: 16,
            damping: 1,
            boundaryDamping: 4,
          ),
        );
        final texture = field.texture, bytes = field.logicalBytes;
        await field.step(initial.withTick(1));
        expect((await field.debugState()).every((v) => v == 0), isTrue);
        expect(field.mode, OceanInteractionMode.visualOnly);
        expect(field.physicalHeightErrorBound, isNull);
        expect(
          field.enqueue(
            OceanInteraction(
              id: OceanInteractionId('drop', 0),
              time: initial.withTick(2),
              ecefPosition: field.anchorEcef,
              relativeVelocity: Vec3.zero,
              radiusMetres: 2,
              energy: .01,
            ),
          ),
          OceanInteractionAdmission.accepted,
        );
        await field.step(initial.withTick(2));
        final state = await field.debugState();
        for (var y = 0; y < 32; y++) {
          for (var x = 0; x < 32; x++) {
            final h = state[(y * 32 + x) * 4];
            expect(h, closeTo(state[(y * 32 + 31 - x) * 4], 1e-6));
            expect(h, closeTo(state[((31 - y) * 32 + x) * 4], 1e-6));
            final px = (x - 15.5) * field.settings.cellMetres,
                py = (y - 15.5) * field.settings.cellMetres;
            if (px * px + py * py > 4) expect(h, 0);
          }
        }
        final first = state.fold(0.0, (sum, v) => sum + v * v);
        expect(first, greaterThan(0));
        for (var tick = 3; tick <= 242; tick++) {
          await field.step(initial.withTick(tick));
        }
        final last = await field.debugState();
        // Height and previous height dominate this zero-foam fixture.
        expect(last.fold(0.0, (sum, v) => sum + v * v), lessThan(first * .5));
        expect(last.every((v) => v.isFinite), isTrue);
        expect(identical(field.texture, texture), isTrue);
        expect(field.logicalBytes, bytes);
        await field.close();
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'integer-cell recentering retains overlap and reset replays the same event',
    () async {
      final backend = await NativeBackend.create(),
          scope = GpuScope.fromBackend(backend);
      try {
        final field = await OceanInteractionField.create(
          scope,
          anchorEcef: const Vec3(6378137, 0, 0),
          initialTime: initial,
          settings: OceanInteractionSettings(resolution: 32, extentMetres: 16),
        );
        OceanInteraction splash(int generation) => OceanInteraction(
          id: OceanInteractionId('drop', 0),
          time: GeoInstant(
            tick: 1,
            hz: 60,
            epoch: initial.epoch,
            generation: generation,
          ),
          ecefPosition: const Vec3(6378137, 0, 0),
          relativeVelocity: Vec3.zero,
          radiusMetres: 2,
          energy: .01,
        );
        field.enqueue(splash(0));
        await field.step(initial.withTick(1));
        final original = await field.debugState();
        await field.recenter(
          field.anchorEcef + field.east * field.settings.cellMetres * 3,
        );
        final moved = await field.debugState();
        for (var y = 0; y < 32; y++) {
          for (var x = 0; x < 29; x++) {
            expect(moved[(y * 32 + x) * 4], original[(y * 32 + x + 3) * 4]);
          }
        }
        await field.recenter(const Vec3(6378137, 0, 0));
        await field.reset(1);
        expect((await field.debugState()).every((v) => v == 0), isTrue);
        field.enqueue(splash(1));
        await field.step(
          GeoInstant(tick: 1, hz: 60, epoch: initial.epoch, generation: 1),
        );
        expect(await field.debugState(), original);
        await field.close();
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
