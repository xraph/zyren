import 'package:test/test.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

FrameStats sample(
  int frame,
  int? ns, {
  String status = 'complete',
  int count = 1,
}) => FrameStats(
  frameId: frame,
  physicalSize: PhysicalSize(16, 16),
  presentationPath: PresentationPath.readback,
  cpuBuildTime: Duration.zero,
  cpuSubmitTime: Duration.zero,
  drawCalls: 0,
  triangles: 0,
  readbackBytes: 0,
  uploadedBytes: 0,
  profile: NativeFrameProfile.fromJson({
    'status': status,
    'gpuTimeNs': ns,
    'gpuTimeSource': ns == null ? 'unavailable' : 'metalCommandBuffer',
    'submissionCount': count,
    'drawPreparationBuffers': 0,
    'drawPreparationBindGroups': 0,
    'uploadBytes': 0,
    'passes': <String, Object?>{},
  }),
);

void main() {
  test('scene pressure is bounded with hysteresis, cooldown and recovery', () {
    final c = CloudSceneFrameController(
      CloudSceneFrameBudget(
        pressureSamples: 2,
        recoverySamples: 3,
        cooldownSamples: 2,
      ),
    );
    expect(c.observe(sample(0, 30000000)), false);
    expect(c.observe(sample(1, 30000000)), true);
    expect((c.rayStride, c.shadowCadence), (4, 2));
    for (var n = 2; n < 6; n++) {
      c.observe(sample(n, 30000000));
    }
    expect((c.rayStride, c.shadowCadence), (8, 4));
    for (var n = 6; n < 40; n++) {
      c.observe(sample(n, 30000000));
    }
    expect(c.level, 2);
    for (var n = 40; n < 43; n++) {
      c.observe(sample(n, 1000000));
    }
    expect(c.level, 1);
    for (var n = 43; n < 48; n++) {
      c.observe(sample(n, 1000000));
    }
    expect(c.level, 0);
    expect(c.transitions, 4);
  });
  test(
    'null, partial, duplicate and ambiguous timing cannot lower quality',
    () {
      final c = CloudSceneFrameController(
        CloudSceneFrameBudget(pressureSamples: 2),
      );
      c.observe(sample(0, 30000000));
      c.observe(sample(1, null));
      c.observe(sample(2, 30000000));
      c.observe(sample(3, 30000000, status: 'incomplete'));
      c.observe(sample(4, 30000000));
      c.observe(sample(5, 30000000, count: 2));
      c.observe(sample(6, 30000000));
      c.observe(sample(6, 30000000));
      expect(c.level, 0);
      c.observe(sample(7, 30000000));
      expect(c.level, 1);
      for (var n = 8; n < 100; n++) {
        c.observe(sample(n, null));
      }
      expect(c.level, 1);
      expect(c.sceneGpuTimeNs, null);
      expect(
        c.toJson()['timingScope'],
        'completedSceneSubmissionExcludingShadowGraphs',
      );
    },
  );
  test('budget rejects invalid sample bounds', () {
    expect(
      () => CloudSceneFrameBudget(target: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => CloudSceneFrameBudget(pressureSamples: 0),
      throwsArgumentError,
    );
    expect(
      () => CloudSceneFrameBudget(recoverySamples: 0),
      throwsArgumentError,
    );
    expect(
      () => CloudSceneFrameBudget(cooldownSamples: -1),
      throwsArgumentError,
    );
  });
}
