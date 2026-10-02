import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_splats/zyren_splats.dart';
import 'package:zyren_splats/agents.dart';
import 'package:zyren_agents/zyren_agents.dart';

GaussianSplat splat(double z, Color3 color) => GaussianSplat(
  mean: Vec3(0, 0, z),
  covariance: GaussianCovariance(xx: .04, yy: .01, zz: .01),
  color: color,
  opacity: .8,
);
void main() {
  test(
    'native anisotropic Gaussian pixels, sorted blending and resource retirement',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      try {
        final renderer = await GaussianSplatRenderer.create(
          owner,
          GaussianCloudData(
            sourceUri: Uri.parse('memory:gaussians'),
            sourceVersion: '1',
            splats: [
              splat(1, const Color3(1, 0, 0)),
              splat(-1, const Color3(0, 0, 1)),
            ],
          ),
        );
        final camera = OrthographicCamera();
        final scene = Scene()..add(renderer.object);
        final registry = AgentRegistry();
        final provider = GaussianAgentProvider.forRenderer(
          renderer,
          instanceId: 'native-Gaussians',
          view: AgentViewportProvider(
            sceneId: 'native-scene',
            documentId: 'fixture',
            instanceId: 'offscreen',
            scene: scene,
            camera: () => camera,
            viewport: () => const ViewportMetrics(100, 100),
          ),
        );
        provider.register(registry, onClose: renderer.onClose);
        final frame = await renderer.render(
          camera: camera,
          size: PhysicalSize(100, 100),
        );
        for (final (x, y) in [(50, 50), (60, 50), (50, 55), (80, 50)]) {
          final dx = x + .5 - 50, dy = 50 - (y + .5);
          final q = dx * dx / 100 + dy * dy / 25;
          final alpha = q > 9 ? 0.0 : .8 * math.exp(-.5 * q);
          final offset = (y * 100 + x) * 4;
          expect(frame.pixels[offset] / 255, closeTo(alpha, 2 / 255));
          expect(
            frame.pixels[offset + 2] / 255,
            closeTo(alpha * (1 - alpha), 2 / 255),
          );
          expect(
            frame.pixels[offset + 3] / 255,
            closeTo(alpha + alpha * (1 - alpha), 2 / 255),
          );
        }
        expect((await backend.resourceStats()).residentBytes, 0);
        final estimate = await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'estimate',
          arguments: {'x': 50, 'y': 50},
        );
        expect(estimate.status, AgentStatus.ok);
        expect((estimate.data['hits'] as List).single['recordIndex'], 0);
        final pending = renderer.render(
          camera: camera,
          size: PhysicalSize(64, 64),
        );
        await expectLater(
          renderer.render(camera: camera, size: PhysicalSize(64, 64)),
          throwsStateError,
        );
        final closing = renderer.close();
        await pending;
        await closing;
        expect(registry.discover()['providers'], isEmpty);
        registry.dispose();
        await renderer.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).cachedPipelines, 0);
        await expectLater(
          renderer.render(camera: camera, size: PhysicalSize(64, 64)),
          throwsStateError,
        );
        final bounded = await GaussianSplatRenderer.create(
          owner,
          renderer.data,
          limits: const SplatLimits(maxTargetBytes: 4096),
        );
        await expectLater(
          bounded.render(camera: camera, size: PhysicalSize(100, 100)),
          throwsStateError,
        );
        expect((await backend.resourceStats()).residentBytes, 0);
        bounded.object.visible = false;
        final blank = await bounded.render(
          camera: camera,
          size: PhysicalSize(16, 16),
        );
        expect(blank.pixels.every((value) => value == 0), isTrue);
        await bounded.close();
        print('Native Gaussian backend: ${backend.capabilities.backend}');
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
