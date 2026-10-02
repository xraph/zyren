import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_native/surfaces.dart';
import 'package:zyren_devtools/gpu_bridge.dart';
import 'package:zyren_devtools/zyren_devtools.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native-view diagnostics measure the presented device and clean up',
    (tester) async {
      expect(Platform.isMacOS || Platform.isAndroid || Platform.isIOS, isTrue);
      final android = Platform.isAndroid;
      final controller = SceneController(
        runtime: android
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      );
      final mesh = controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      controller.camera.position = const Vec3(0, 0, 4);
      final inspector = controller.use(SceneDevtoolsPlugin());
      final bridge = controller.use(GpuInspectionBridge());
      final channel = MethodChannel(
        android ? 'zyren/android-surfaces' : 'zyren/scene-views',
      );
      Future<Map> hostStats() async =>
          (await channel.invokeMapMethod('diagnostics'))!;
      await channel.invokeMethod<void>('connect', {
        'runtime': NativeSurfaces().runtimeToken,
      });
      final baseline = await hostStats();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await controller.whenDisposed;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 320,
              height: 240,
              child: SceneView(controller: controller),
            ),
          ),
        ),
      );
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 1200; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          expect(tester.takeException(), isNull);
          if (controller.status.value case SceneFailed(:final issue)) {
            fail(issue.message);
          }
          if (ready()) return;
        }
        fail('Native diagnostic host did not reach the expected state.');
      }

      await until(
        () =>
            controller.status.value is SceneReady &&
            inspector.frames.isNotEmpty,
      );
      final info = await controller.ready;
      expect(
        info.presentationPath,
        android ? PresentationPath.sharedTexture : PresentationPath.nativeView,
      );
      final first = (await inspector.inspectGpu(allocationLimit: 1))!;
      expect(first.residentBytes, isNull);
      expect(first.registryPayloadBytes, greaterThan(0));
      final previous = inspector.frames.length;
      mesh.rotateY(.2);
      controller.invalidate();
      await until(() => inspector.frames.length > previous);
      final measured = (await inspector.inspectGpu(allocationLimit: 1))!;
      expect(measured.submittedFrames, greaterThan(first.submittedFrames));
      expect(measured.residentBytes, isNull);
      expect(measured.allocations.length, lessThanOrEqualTo(1));
      expect(measured.memoryReports, isNotEmpty);
      if (android) {
        for (final memory in measured.memoryReports) {
          expect(memory.source, 'vulkan.EXT_memory_budget');
          expect(memory.scope, 'processHeap');
          if (memory.status == 'available') {
            expect(memory.heapIndex, isNonNegative);
            expect(memory.deviceLocal, isNotNull);
            expect(memory.usageBytes, isNonNegative);
            expect(memory.budgetBytes, greaterThan(0));
            expect(memory.usageIsEstimate, isTrue);
            expect(memory.budgetIsEstimate, isTrue);
          } else {
            expect(memory.status, 'unsupported');
            expect(memory.reason, isNotEmpty);
            expect(memory.usageBytes, isNull);
            expect(memory.budgetBytes, isNull);
          }
          expect(memory.recommendedMaxWorkingSetBytes, isNull);
        }
        expect(inspector.capabilities.backend, 'Vulkan');
        expect(measured.allocatorSource, 'wgpu.suballocator');
        expect(measured.allocatorUsedBytes, greaterThan(0));
        expect(
          measured.allocatorReservedBytes,
          greaterThanOrEqualTo(measured.allocatorUsedBytes!),
        );
        expect(measured.allocatorAllocations.length, lessThanOrEqualTo(1));
        expect(measured.gpuTimeSource, 'wgpu.timestampQuery.commandEncoder');
        expect(measured.lastSubmissionGpuTimeNs, greaterThan(0));
        expect(measured.diagnosticReadbackBytes, greaterThanOrEqualTo(16));
        final client = GpuInspectionClient(
          endpoint: bridge.endpoint,
          sessionToken: bridge.sessionToken,
        );
        try {
          expect(
            (await client.inspectGpu(allocationLimit: 1))['submittedFrames'],
            measured.submittedFrames,
          );
        } finally {
          client.close();
        }
      } else {
        final memory = measured.memoryReports.single;
        expect(memory.status, 'available');
        expect(memory.source, 'metal.deviceMemory');
        expect(memory.scope, 'processDevice');
        expect(memory.usageBytes, greaterThan(0));
        expect(memory.recommendedMaxWorkingSetBytes, greaterThan(0));
        expect(memory.usageIsEstimate, isFalse);
        expect(memory.budgetBytes, isNull);
        expect(memory.unifiedMemory, isNotNull);
        expect(measured.deviceAllocationSource, 'metal.currentAllocatedSize');
        expect(measured.deviceAllocatedBytes, greaterThan(0));
        expect(measured.gpuTimeSource, 'metal.commandBuffer.startEndTime');
        expect(measured.lastSubmissionGpuTimeNs, greaterThan(0));
        expect(measured.diagnosticReadbackBytes, 0);
      }
      expect(
        inspector.frames.map((frame) => frame.readbackBytes),
        everyElement(0),
      );
      debugPrint('GPU_DIAGNOSTICS ${jsonEncode(measured.toJson())}');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await controller.whenDisposed;
      expect(() => bridge.endpoint, throwsStateError);
      expect(inspector.isAttached, isFalse);
      await expectLater(inspector.inspectGpu(), throwsStateError);
      final closed = await hostStats();
      expect(closed['renderers'], baseline['renderers']);
      expect(closed[android ? 'surfaces' : 'heldDrawables'], 0);
      expect(closed['readbackBytes'], baseline['readbackBytes']);
      binding.reportData = {
        'gpuDiagnostics': measured.toJson(),
        'presentationPath': info.presentationPath.name,
        'cleanupVerified': true,
        'scenePixelReadbacks': 0,
      };
    },
  );
}
