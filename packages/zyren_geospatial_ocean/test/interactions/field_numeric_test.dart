import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import 'events_test.dart' show initial, event;

void main() {
  test('native recurrence agrees with an independent scalar grid', () async {
    final backend = await NativeBackend.create();
    final owner = GpuScope.fromBackend(backend);
    try {
      final options = OceanInteractionSettings(
        resolution: 16,
        extentMetres: 4,
        absorbingWidthCells: 3,
        waveSpeed: 20,
        damping: .7,
      );
      final field = await OceanInteractionField.create(
        owner,
        anchorEcef: const Vec3(6378137, 0, 0),
        initialTime: initial,
        settings: options,
      );
      expect(field.substeps, greaterThan(1));
      field.enqueue(
        OceanInteraction(
          id: OceanInteractionId('drop', 0),
          time: initial.withTick(1),
          ecefPosition: field.anchorEcef,
          relativeVelocity: Vec3.zero,
          radiusMetres: 1,
          energy: .01,
        ),
      );
      await field.step(initial.withTick(1));
      final seed = await field.debugState();
      var heights = List.generate(256, (i) => seed[i * 4]);
      var previous = List.generate(256, (i) => seed[i * 4 + 1]);
      final dt = 1 / (60 * field.substeps), dx = options.cellMetres;
      for (var tick = 2; tick <= 16; tick++) {
        for (var substep = 0; substep < field.substeps; substep++) {
          final next = List.filled(256, 0.0);
          for (var y = 1; y < 15; y++) {
            for (var x = 1; x < 15; x++) {
              final at = y * 16 + x;
              final edge = math.min(math.min(x, y), math.min(15 - x, 15 - y));
              final ramp = math.max(0, 1 - edge / options.absorbingWidthCells);
              final drag =
                  options.damping + options.boundaryDamping * ramp * ramp;
              final lap =
                  heights[at - 1] +
                  heights[at + 1] +
                  heights[at - 16] +
                  heights[at + 16] -
                  4 * heights[at];
              next[at] =
                  (2 * heights[at] -
                          previous[at] +
                          math.pow(options.waveSpeed * dt / dx, 2) * lap -
                          drag * dt * (heights[at] - previous[at]))
                      .clamp(
                        -options.maxDisplacementMetres,
                        options.maxDisplacementMetres,
                      );
            }
          }
          previous = heights;
          heights = next;
        }
        await field.step(initial.withTick(tick));
      }
      final actual = await field.debugState();
      for (var i = 0; i < 256; i++) {
        expect(actual[i * 4], closeTo(heights[i], 2e-7));
        expect(actual[i * 4 + 1], closeTo(previous[i], 2e-7));
      }
    } finally {
      await owner.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

  test(
    'foam follows bounded emission, transport and exponential decay',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final field = await OceanInteractionField.create(
          owner,
          anchorEcef: const Vec3(6378137, 0, 0),
          initialTime: initial,
          settings: OceanInteractionSettings(
            resolution: 16,
            extentMetres: 4,
            absorbingWidthCells: 3,
            foamLifetimeSeconds: 2,
            foamGain: .5,
          ),
        );
        final source = Float32List(16 * 16 * 4);
        source[(8 * 16 + 6) * 4] = 12;
        await field.writeFoamSources(source);
        await field.step(initial.withTick(1));
        final born = await field.debugState(), at = (8 * 16 + 6) * 4 + 2;
        expect(born[at], closeTo(1 - math.exp(-.5 * 12 / 60), 1e-7));
        await field.writeFoamSources(Float32List(source.length));
        await field.step(
          initial.withTick(2),
          foamVelocityEcef: field.east * (60 * field.settings.cellMetres),
        );
        final moved = await field.debugState();
        expect(moved[at], closeTo(0, 1e-7));
        expect(moved[at + 4], closeTo(born[at] * math.exp(-1 / 120), 1e-7));
        for (var tick = 3; tick <= 62; tick++) {
          await field.step(initial.withTick(tick));
        }
        expect(
          (await field.debugState())[at + 4],
          closeTo(moved[at + 4] * math.exp(-.5), 3e-6),
        );
        expect(
          (await field.debugState()).whereIndexedHeight().every((v) => v == 0),
          isTrue,
        );
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'admission and concurrent close preserve native resource baseline over 100 cycles',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final options = OceanInteractionSettings(
        resolution: 16,
        extentMetres: 4,
        absorbingWidthCells: 3,
      );
      try {
        final baseline = await backend.resourceStats();
        await expectLater(
          OceanInteractionField.create(
            owner,
            anchorEcef: const Vec3(6378137, 0, 0),
            initialTime: initial,
            settings: options,
            maxLogicalBytes: 1,
          ),
          throwsA(isA<ResourceException>()),
        );
        for (var cycle = 0; cycle < 100; cycle++) {
          final field = await OceanInteractionField.create(
            owner,
            anchorEcef: const Vec3(6378137, 0, 0),
            initialTime: initial,
            settings: options,
            maxPerTick: 1,
          );
          expect(
            field.enqueue(event('boat', 0, 1)),
            OceanInteractionAdmission.accepted,
          );
          expect(
            field.enqueue(event('debris', 0, 1)),
            OceanInteractionAdmission.tickBudget,
          );
          final step = field.step(initial.withTick(1));
          expect(() => field.enqueue(event('boat', 1, 2)), throwsStateError);
          await expectLater(field.step(initial.withTick(1)), throwsStateError);
          final closing = field.close();
          await step;
          await closing;
          expect(field.isClosed, isTrue);
          expect(
            (await backend.resourceStats()).liveAllocations,
            baseline.liveAllocations,
          );
        }
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

extension on Float32List {
  Iterable<double> whereIndexedHeight() sync* {
    for (var i = 0; i < length; i += 4) {
      yield this[i];
    }
  }
}
