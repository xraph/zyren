import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_scientific/agents.dart';
import 'package:zyren_scientific/zyren_scientific.dart';

import 'scientific_test.dart' show grid, transfer, slice;

void main() {
  test('native scalar colors, missing holes, picking and removal', () async {
    final backend = await NativeBackend.create();
    final scene = Scene()..background = null;
    final camera = OrthographicCamera(
      position: const Vec3(.5, .5, 5),
      target: const Vec3(.5, .5, 0),
      left: -.5,
      right: .5,
      bottom: -.5,
      top: .5,
    );
    try {
      final field = grid(x: 2, y: 2, z: 2, values: [0, 1, 0, 1, 2, 3, 2, 3]);
      final result = ScalarSlice.build(
        grid: field,
        transfer: transfer(min: 1, max: 2),
        axis: SliceAxis.z,
        index: .5,
        coordinateTolerance: 0,
      );
      final view = ScientificSliceView(
        id: 'native-field',
        scene: scene,
        slice: result,
        coordinateTolerance: 0,
      );
      final registry = AgentRegistry(grantedScopes: {'scientific.edit'});
      addTearDown(view.dispose);
      addTearDown(registry.dispose);
      registerScientificView(registry, view);
      final scientific = ScientificAgentProvider(view);
      registry.register(
        AgentViewportProvider(
          sceneId: 'native-scene',
          documentId: 'synthetic-document',
          instanceId: 'native-view',
          scene: scene,
          camera: () => camera,
          viewport: () => const ViewportMetrics(65, 65),
          metadata: scientific.metadata,
          units: 'm',
        ),
      );
      final frame =
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(65, 65),
                ),
              )
              as ReadbackOutput;
      expect(frame.stats.drawCalls, greaterThanOrEqualTo(1));
      expect(frame.stats.triangles, greaterThanOrEqualTo(2));
      expect(
        backend.capabilities.backend,
        anyOf('Metal', 'Vulkan', 'Dx12', 'DX12'),
      );
      var maxPixelError = 0;
      int srgb(double linear) =>
          (255 *
                  (linear <= .0031308
                      ? 12.92 * linear
                      : 1.055 * math.pow(linear, 1 / 2.4) - .055))
              .round();
      for (final x in [8, 16, 32, 48, 56]) {
        final index = (32 * 65 + x) * 4;
        final t = (x + .5) / 65;
        final redError = (frame.image.pixels[index] - srgb(t)).abs();
        final blueError = (frame.image.pixels[index + 2] - srgb(1 - t)).abs();
        maxPixelError = math.max(maxPixelError, math.max(redError, blueError));
        expect(redError, lessThanOrEqualTo(2));
        expect(blueError, lessThanOrEqualTo(2));
        expect(frame.image.pixels[index + 1], 0);
        expect(frame.image.pixels[index + 3], 255);
      }
      final pick = await registry.call(
        providerId: 'zyren.viewport',
        instanceId: 'native-view',
        tool: 'pick',
        arguments: {'x': 32.5, 'y': 32.5},
      );
      expect(pick.status, AgentStatus.ok);
      final hit = (pick.data['hits'] as List).single as Map;
      final sampled = await registry.call(
        providerId: 'zyren.scientific',
        instanceId: 'native-field',
        tool: 'sample_triangle',
        expectedRevision: 0,
        arguments: {
          'runtimeObjectId': (hit['object'] as Map)['runtimeId'],
          'sceneRevision': pick.data['sceneRevision'],
          'triangleIndex': hit['triangleIndex'],
          'barycentric': hit['barycentric'],
        },
      );
      expect(sampled.status, AgentStatus.ok);
      expect(sampled.data['value'], closeTo(1.5, 1e-12));
      final changed = await registry.call(
        providerId: 'zyren.scientific',
        instanceId: 'native-field',
        tool: 'set_slice',
        expectedRevision: 0,
        idempotencyKey: 'native-next-plane',
        arguments: {'axis': 'z', 'index': 1},
      );
      expect(changed.status, AgentStatus.ok);
      final changedFrame =
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(65, 65),
                ),
              )
              as ReadbackOutput;
      final center = (32 * 65 + 32) * 4;
      expect(changedFrame.image.pixels.sublist(center, center + 4), [
        255,
        0,
        0,
        255,
      ]);
      view.dispose();
      final missing = grid(
        x: 4,
        y: 4,
        z: 1,
        values: [
          for (var j = 0; j < 4; j++)
            for (var i = 0; i < 4; i++) i == 1 && j == 1 ? null : 20,
        ],
      );
      final withHole = slice(missing, index: 0).createMesh()!;
      scene.add(withHole);
      camera
        ..position = const Vec3(1.5, 1.5, 5)
        ..target = const Vec3(1.5, 1.5, 0)
        ..left = -1.5
        ..right = 1.5
        ..bottom = -1.5
        ..top = 1.5;
      final holeFrame =
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(65, 65),
                ),
              )
              as ReadbackOutput;
      final raycaster = Raycaster();
      for (final (x, y) in [(10, 55), (32, 32), (55, 10)]) {
        final hit = raycaster
            .captureFromCamera(
              scene,
              camera,
              ViewportPoint(x + .5, y + .5),
              logicalWidth: 65,
              logicalHeight: 65,
            )
            .intersectFirst();
        final alpha = holeFrame.image.pixels[(y * 65 + x) * 4 + 3];
        expect(alpha > 0, hit != null);
        expect(alpha > 0, x == 55);
      }
      scene.remove(withHole);
      final empty =
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(65, 65),
                ),
              )
              as ReadbackOutput;
      expect(empty.image.pixels.every((value) => value == 0), isTrue);
      print(
        'SCIENTIFIC_NATIVE backend=${backend.capabilities.backend} adapter=${backend.capabilities.adapterName} maxPixelError=$maxPixelError/255, missing-cell/raycast agreement, removal clear',
      );
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
