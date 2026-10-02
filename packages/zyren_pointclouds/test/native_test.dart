import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'package:zyren_pointclouds/agents.dart';
import 'package:zyren_agents/zyren_agents.dart';

void main() {
  test(
    'native point markers render, source query resolves and close removes pixels',
    () async {
      final backend = await NativeBackend.create();
      try {
        final data = PointCloudData(
          sourceUri: Uri.parse('memory:survey'),
          sourceVersion: '1',
          points: [const Vec3(-.5, 0, 0), const Vec3(.5, 0, 0)],
        );
        final cloud = ScenePointCloud(
          data: data,
          material: PointsMaterial(size: 12, color: const Color3(1, 0, 0)),
        );
        final scene = Scene()..background = const Color3(0, 0, 0);
        scene.add(cloud.object);
        final camera = OrthographicCamera(
          position: const Vec3(0, 0, 3),
          near: .1,
          far: 10,
        );
        Future<ReadbackOutput> render() async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(128, 128),
                  ),
                )
                as ReadbackOutput;
        final frame = await render();
        for (final x in [32, 96]) {
          final pixel = (64 * 128 + x) * 4;
          expect(frame.image.pixels[pixel], greaterThan(200));
          expect(frame.image.pixels[pixel + 1], lessThan(10));
        }
        final ray = camera.rayFromNdc(.5, 0, 1);
        expect(
          cloud.pick(Ray(ray.origin, ray.direction), radius: .01)!.identity.$3,
          1,
        );
        final registry = AgentRegistry();
        final provider = PointCloudAgentProvider(
          cloud: cloud,
          instanceId: 'native-cloud',
          view: AgentViewportProvider(
            sceneId: 'native-scene',
            documentId: 'fixture',
            instanceId: 'offscreen',
            scene: scene,
            camera: () => camera,
            viewport: () => const ViewportMetrics(128, 128),
          ),
        );
        provider.register(registry);
        final hit = await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'pick',
          arguments: {'x': 96, 'y': 64, 'radius': .01},
        );
        expect(hit.status, AgentStatus.ok);
        expect((hit.data['hits'] as List).single['recordIndex'], 1);
        cloud.close();
        expect(registry.discover()['providers'], isEmpty);
        registry.dispose();
        final empty = await render();
        expect(empty.image.pixels[(64 * 128 + 96) * 4], 0);
        print('Native point backend: ${backend.capabilities.backend}');
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
