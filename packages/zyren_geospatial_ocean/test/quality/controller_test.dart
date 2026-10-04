import 'dart:io';
import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native quality publication is atomic, transitions reuse resources and failures preserve the current set',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final state = fixtureSea(resolution: 128);
      var failBuild = false, failTransition = false;
      final patch = OceanPatchId(face: 0, level: 16, x: 32768, y: 32768);
      Future<OceanQualityPlan<OceanWaterMaterial>> plan(
        OceanQualitySettings settings,
        OceanQualitySettings? previous,
      ) async => OceanQualityPlan(
        activeEffects: {
          'surface',
          if (settings.ssrSteps > 0) 'screenSpaceReflection',
        },
        additionalPayloads: {'material': 1104},
        build: (context, waves) async {
          final material = await OceanWaterMaterial.create(
            context.gpu,
            waves: waves,
            patch: patch,
            geometrySpacingMetres: .1,
            reflections: settings.reflections,
          );
          context.onClose(material.close);
          if (failBuild || (failTransition && previous != null)) {
            throw StateError('Injected material preparation failure.');
          }
          return material;
        },
      );
      try {
        final controller = await OceanController.create<OceanWaterMaterial>(
          owner,
          state: state,
          chartIds: [0],
          capabilities: backend.capabilities,
          quality: OceanRenderQuality.low.settings.copyWith(
            gpuBudgetBytes: 2 * 1024 * 1024,
          ),
          plan: plan,
          transitionDuration: const Duration(milliseconds: 200),
        );
        final old = controller.resources, quality = controller.effectiveQuality;
        final revision = controller.seaStateRevision;
        final before = (await old.debugSurface([Vec3.zero])).single;
        final allocations = (await backend.resourceStats()).liveAllocations;
        await expectLater(
          controller.setQuality(OceanRenderQuality.ultra.settings),
          throwsA(isA<OceanQualityException>()),
        );
        expect(controller.resources, same(old));
        expect(controller.effectiveQuality, same(quality));
        expect(controller.seaStateRevision, revision);
        expect((await backend.resourceStats()).liveAllocations, allocations);
        failBuild = true;
        await expectLater(
          controller.setQuality(OceanRenderQuality.medium.settings),
          throwsStateError,
        );
        expect(controller.resources, same(old));
        expect(controller.isReady, isTrue);
        expect((await backend.resourceStats()).liveAllocations, allocations);
        failBuild = false;
        failTransition = true;
        await expectLater(
          controller.setQuality(OceanRenderQuality.medium.settings),
          throwsStateError,
        );
        expect(controller.resources, same(old));
        expect(controller.effectiveQuality, same(quality));
        expect(controller.isReady, isTrue);
        expect((await backend.resourceStats()).liveAllocations, allocations);
        failTransition = false;
        await backend.configureResourceBudget(16 * 1024 * 1024);
        final blocker = owner.resources.createChild();
        await blocker.createBuffer(
          BufferDescriptor(
            size:
                16 * 1024 * 1024 -
                (await backend.resourceStats()).residentBytes -
                20000,
            usage: {BufferUsage.copyDestination},
          ),
        );
        final pressured = (await backend.resourceStats()).liveAllocations;
        await expectLater(
          controller.setQuality(OceanRenderQuality.medium.settings),
          throwsA(isA<ResourceException>()),
        );
        expect(controller.resources, same(old));
        expect((await backend.resourceStats()).liveAllocations, pressured);
        expect(
          (await old.debugSurface([Vec3.zero])).single.offsetEcef,
          before.offsetEcef,
        );
        await blocker.close();
        await backend.configureResourceBudget(256 * 1024 * 1024);
        await controller.setQuality(OceanRenderQuality.medium.settings);
        expect(controller.isTransitioning, isTrue);
        expect(controller.effectiveQuality.preset, OceanRenderQuality.medium);
        expect(controller.seaStateRevision, revision);
        expect(controller.activeEffects, contains('screenSpaceReflection'));
        final start = (await controller.resources.debugSurface([
          Vec3.zero,
        ])).single;
        expect(start.offsetEcef.distanceTo(before.offsetEcef), lessThan(2e-6));
        final steady = (await backend.resourceStats()).liveAllocations;
        for (var i = 1; i <= 10; i++) {
          await controller.advance(
            seconds: i / 60,
            elapsed: Duration(milliseconds: i * 10),
          );
        }
        expect(controller.transitionFraction, .5);
        final report = controller.diagnostics();
        expect(report.passes.map((p) => p.dispatches), [25, 22, 1]);
        expect(report.passes.every((p) => p.gpuTime == null), isTrue);

        expect((await backend.resourceStats()).liveAllocations, steady);
        expect(old.isClosed, isFalse);
        await expectLater(controller.setQuality(quality), throwsStateError);
        await controller.advance(
          seconds: 1,
          elapsed: const Duration(milliseconds: 200),
        );
        expect(controller.isTransitioning, isFalse);
        expect(old.isClosed, isTrue);
        expect(controller.waves.resolution, 128);
        expect(
          controller.estimatedBytes,
          OceanWaveStream.estimateBytes(128, 1, 1) + 1104,
        );
        final pending = controller.advance(
          seconds: 2,
          elapsed: const Duration(seconds: 1),
        );
        await expectLater(
          controller.advance(seconds: 2, elapsed: const Duration(seconds: 1)),
          throwsStateError,
        );
        await pending;
        await controller.setQuality(quality);
        expect(
          controller.admission.peakBytes,
          greaterThan(quality.gpuBudgetBytes),
        );
        expect(
          controller.admission.peakBudgetBytes,
          OceanRenderQuality.medium.settings.gpuBudgetBytes,
        );
        await controller.advance(
          seconds: 2.5,
          elapsed: const Duration(milliseconds: 1300),
        );
        expect(controller.isTransitioning, isFalse);
        expect(controller.estimatedBytes, lessThan(quality.gpuBudgetBytes));
        expect(controller.effectiveQuality, same(quality));
        await controller.close();
        expect(controller.isReady, isFalse);
        expect((await backend.resourceStats()).liveAllocations, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'close drains pending quality preparation without publishing its candidate',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final gate = Completer<void>(), entered = Completer<void>();
      try {
        final controller = await OceanController.create<Object>(
          owner,
          state: fixtureSea(resolution: 128),
          chartIds: [0],
          capabilities: backend.capabilities,
          quality: OceanRenderQuality.low.settings,
          plan: (settings, previous) async {
            if (settings.fftResolution == 128) {
              if (!entered.isCompleted) entered.complete();
              await gate.future;
            }
            return OceanQualityPlan(build: (context, waves) async => Object());
          },
        );
        final revision = controller.publicationRevision;
        final preparing = controller.setQuality(
          OceanRenderQuality.medium.settings,
        );
        await entered.future;
        final closing = controller.close();
        gate.complete();
        await expectLater(preparing, throwsStateError);
        await closing;
        expect(controller.publicationRevision, revision);
        expect((await backend.resourceStats()).liveAllocations, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
