import 'package:test/test.dart';
import 'package:zyren/rendering.dart';

void main() {
  test(
    'native schema preserves unknown passes and complete nanosecond phases',
    () {
      final json = <String, Object?>{
        'status': 'complete',
        'cpuPrepareNs': 1234567,
        'cpuEncodeNs': 2345678,
        'cpuCompletionWaitNs': 3456789,
        'gpuTimeNs': 4567890,
        'gpuTimeSource': 'metal.commandBuffer.startEndTime',
        'submissionCount': 1,
        'drawPreparationBuffers': 2,
        'drawPreparationBindGroups': 3,
        'drawCacheReuses': 3,
        'drawUniformReuses': 2,
        'drawUniformWriteCalls': 1,
        'drawUniformWriteBytes': 16,
        'drawUniformSkippedWrites': 2,
        'drawCacheEntries': 6,
        'drawCacheUniformBytes': 1536,
        'uploadBytes': 1024,
        'executedMeshDraws': 4,
        'opaqueBatchDraws': 2,
        'batchedSourceDraws': 20,
        'pipelineSwitches': 3,
        'bindGroupSwitches': 4,
        'automaticInstanceUploadBytes': 2560,
        'passes': {
          'scene': {'executed': true, 'gpuTimeNs': null, 'drawCalls': 4},
          'transmission': {'executed': false, 'gpuTimeNs': null},
        },
        'resources': {'submissionCount': 4, 'gpuTimeNs': null},
      };
      final profile = NativeFrameProfile.fromJson(json);
      expect(profile.toJson(), json);
      expect(profile.drawUniformWriteBytes, 16);
      expect(profile.sceneDrawCalls(20), 4);
      expect(profile.passes['scene']!.drawCalls, 4);
      expect(profile.automaticInstanceUploadBytes, 2560);
      final outlined = Map<String, Object?>.of(json)
        ..['passes'] = {
          'outlines': {'executed': true, 'gpuTimeNs': null},
        };
      expect(NativeFrameProfile.fromJson(outlined).sceneDrawCalls(20), 5);
      outlined['status'] = 'failed';
      expect(NativeFrameProfile.fromJson(outlined).sceneDrawCalls(20), 20);
      final legacy = Map<String, Object?>.of(json);
      for (final key in [
        'executedMeshDraws',
        'opaqueBatchDraws',
        'batchedSourceDraws',
        'pipelineSwitches',
        'bindGroupSwitches',
        'automaticInstanceUploadBytes',
        'drawUniformReuses',
        'drawUniformWriteCalls',
        'drawUniformWriteBytes',
        'drawUniformSkippedWrites',
        'drawCacheEntries',
        'drawCacheUniformBytes',
      ]) {
        legacy.remove(key);
      }
      final unknown = NativeFrameProfile.fromJson(legacy);
      expect(unknown.drawUniformWriteCalls, isNull);
      expect(unknown.executedMeshDraws, isNull);
      expect(unknown.sceneDrawCalls(20), 20);
      expect(unknown.drawCacheUniformBytes, isNull);
      expect(unknown.toJson(), legacy);
      expect(profile.gpuTime, const Duration(microseconds: 4567));
      expect(profile.passes['scene']!.executed, true);
      expect(profile.passes['scene']!.gpuTimeNs, isNull);
      expect(() => profile.passes.clear(), throwsUnsupportedError);
      expect(() => profile.resources.clear(), throwsUnsupportedError);
      final frame = FrameStats(
        frameId: 1,
        physicalSize: PhysicalSize(8, 8),
        presentationPath: PresentationPath.nativeView,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        drawCalls: 0,
        triangles: 0,
        readbackBytes: 0,
        uploadedBytes: 0,
        profile: profile,
      );
      expect(
        frame
            .withSource(
              const FrameSource(
                sceneRevision: 1,
                cameraRevision: 2,
                cameraRuntimeId: 3,
              ),
            )
            .profile,
        same(profile),
      );
    },
  );
}
