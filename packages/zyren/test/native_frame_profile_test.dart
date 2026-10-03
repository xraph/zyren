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
        'drawCacheReuses': null,
        'uploadBytes': 1024,
        'passes': {
          'scene': {'executed': true, 'gpuTimeNs': null},
          'transmission': {'executed': false, 'gpuTimeNs': null},
        },
        'resources': {'submissionCount': 4, 'gpuTimeNs': null},
      };
      final profile = NativeFrameProfile.fromJson(json);
      expect(profile.toJson(), json);
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
