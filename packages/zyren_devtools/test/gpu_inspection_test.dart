import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/gpu_tools.dart';
import 'package:zyren_native/zyren_native.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test(
    'unsupported backend and invalid tool arguments stay explicit',
    () async {
      final inspector = SceneDevtoolsPlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [inspector],
      );
      final tools = GpuInspectionTools(inspector);
      try {
        expect(await tools.call('zyren_gpu_inspect', {}), {
          'available': false,
          'reason': 'backendUnsupported',
        });
        await expectLater(
          tools.call('zyren_gpu_inspect', {'allocationLimit': 257}),
          throwsRangeError,
        );
        await expectLater(
          tools.call('zyren_gpu_inspect', {'allocationLimit': 1.5}),
          throwsArgumentError,
        );
        await expectLater(
          tools.call('zyren_gpu_inspect', {'extra': true}),
          throwsArgumentError,
        );
      } finally {
        await engine.dispose();
      }
      await expectLater(inspector.inspectGpu(), throwsStateError);
    },
  );
  test(
    'native inspector measures last submission and clears allocations after close',
    () async {
      final backend = await NativeBackend.create();
      final inspector = SceneDevtoolsPlugin();
      final engine = await SceneEngine.create(
        scene: Scene()..add(Mesh(BoxGeometry(), UnlitMaterial())),
        camera: PerspectiveCamera()..position = const Vec3(0, 0, 4),
        backendFactory: () async => backend,
        plugins: [inspector],
      );
      final resources = backend.createResourceScope();
      try {
        expect((await inspector.inspectGpu())!.lastSubmissionGpuTimeNs, isNull);
        await resources.createBuffer(
          BufferDescriptor(size: 32, usage: {BufferUsage.copyDestination}),
        );
        await resources.createBuffer(
          BufferDescriptor(size: 16, usage: {BufferUsage.copyDestination}),
        );
        final before = (await inspector.inspectGpu(allocationLimit: 1))!;
        expect(before.registryPayloadBytes, 48);
        expect(before.truncated, isTrue);
        expect(before.allocations.length, 1);
        await resources.close();
        expect((await inspector.inspectGpu())!.totalAllocations, 0);
        await engine.render(elapsed: Duration.zero, width: 32, height: 32);
        final result = await GpuInspectionTools(
          inspector,
        ).call('zyren_gpu_inspect', {});
        expect(result['residentBytes'], isNull);
        expect(result['submittedFrames'], 1);
        if (backend.capabilities.backend == 'Metal') {
          final memory = (result['memoryReports'] as List).single as Map;
          expect(memory['source'], 'metal.deviceMemory');
          expect(memory['status'], 'available');
          expect(memory['scope'], 'processDevice');
          expect(memory['usageBytes'], greaterThan(0));
          expect(memory['recommendedMaxWorkingSetBytes'], greaterThan(0));
          expect(memory['budgetBytes'], isNull);
          expect(result['deviceAllocatedBytes'], greaterThan(0));
          expect(result['lastSubmissionGpuTimeNs'], greaterThan(0));
          expect(result['gpuTimeSource'], 'metal.commandBuffer.startEndTime');
        }
      } finally {
        await engine.dispose();
      }
      await expectLater(inspector.inspectGpu(), throwsStateError);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
