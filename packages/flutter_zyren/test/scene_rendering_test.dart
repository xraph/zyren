import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'support/backend_fake.dart';
import 'package:zyren/rendering.dart';
import 'support/fakes.dart' show TestPresenter;
import 'controller_test.dart' show host, frames, readback, runtime;
import '../../zyren/test/environment_test.dart' as fixture;
import '../../zyren_gltf/test/model_test.dart' show load;
import '../../zyren_gltf/test/support/animated_fixture.dart' show animatedModel;

// Reference reflection fixture. Exercises real graph validation and resource
// ownership, while native WGSL compilation is qualified separately.
class RenderingDevice extends fixture.EnvironmentDevice {
  @override
  Future<ShaderBuild> compileShader(ShaderSource source) async {
    final key = Object();
    programs.add(key);
    final entries = RegExp(
      r'@(vertex|fragment|compute)\s+(?:@workgroup_size\([^)]*\)\s+)?fn\s+(\w+)',
    ).allMatches(source.code);
    return ShaderBuild(
      key: key,
      entryPoints: [
        for (final e in entries)
          ShaderEntryPoint(
            name: e[2]!,
            stage: ShaderStage.values.byName(e[1]!),
            workgroupSize: e[1] == 'compute' ? (8, 8, 1) : null,
          ),
      ],
    );
  }
}

class RenderingBackend extends fixture.EnvironmentBackend {
  @override
  final device = RenderingDevice();
}

class AnimationReferenceBackend extends FakeBackend {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'animation submission reference',
    features: RenderFeature.values.toSet(),
    limits: DeviceLimits(
      maxTextureDimension2D: 64,
      maxGeometryBytes: 1000000,
      maxJoints: 64,
      maxMorphTargets: 16,
    ),
  );
}

void main() {
  testWidgets(
    'lights retain identity and publish changes, including shadows and cones',
    (tester) async {
      final r = runtime(FakeBackend());
      final point = SceneRef<PointLight>(),
          spot = SceneRef<SpotLight>(),
          hemi = SceneRef<HemisphereLight>(),
          rect = SceneRef<RectAreaLight>();
      Widget scene(double value) => host(
        SceneCanvas(
          runtime: r,
          options: readback,
          children: [
            PointLightNode(ref: point, intensity: value, range: value * 10),
            SpotLightNode(
              ref: spot,
              intensity: value,
              innerConeAngle: value * .1,
              outerConeAngle: value * .2,
            ),
            HemisphereLightNode(
              ref: hemi,
              groundColor: Color3(value * .1, 0, 0),
            ),
            RectAreaLightNode(ref: rect, width: value, height: value * 2),
          ],
        ),
      );
      await tester.pumpWidget(scene(1));
      final originals = [
        point.require,
        spot.require,
        hemi.require,
        rect.require,
      ];
      await tester.pumpWidget(scene(2));
      expect([
        point.require,
        spot.require,
        hemi.require,
        rect.require,
      ], originals);
      expect(point.require.range, 20);
      expect(point.require.intensity, 2);
      expect(spot.require.innerConeAngle, .2);
      expect(spot.require.outerConeAngle, .4);
      expect(hemi.require.groundColor, const Color3(.2, 0, 0));
      expect(rect.require.height, 4);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(point.current, isNull);
    },
  );
  test('textured material equality includes maps and every alpha option', () {
    final map = TextureMap(
      image: TextureImage.fromImage(
        ImageData(
          size: PhysicalSize(1, 1),
          pixels: Uint8List.fromList([255, 255, 255, 255]),
        ),
      ),
    );
    final a = SceneMaterial.standard(
      colorMap: map,
      opacity: .3,
      alphaMode: MaterialAlphaMode.blend,
      side: MaterialSide.front,
    );
    final b = SceneMaterial.standard(
      colorMap: TextureMap(image: map.image),
      opacity: .3,
      alphaMode: MaterialAlphaMode.blend,
      side: MaterialSide.front,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      a,
      isNot(
        SceneMaterial.standard(
          colorMap: map,
          opacity: .4,
          alphaMode: MaterialAlphaMode.blend,
          side: MaterialSide.front,
        ),
      ),
    );
    final material = a.create() as StandardMaterial;
    expect(material.colorMap, same(map));
    expect(material.opacity, .3);
    expect(material.writesDepth, isFalse);
    expect(
      SceneMaterial.unlit(colorMap: map, alphaCutoff: .2).create().alphaCutoff,
      .2,
    );
  });
  testWidgets(
    'instances retain storage until capacity changes and clear removed tints',
    (tester) async {
      final r = runtime(FakeBackend()), ref = SceneRef<InstancedMesh>();
      Widget scene(int capacity, List<Color3> colors) => host(
        SceneCanvas(
          runtime: r,
          options: readback,
          children: [
            InstancedMeshNode(
              ref: ref,
              geometry: const SceneGeometry.box(),
              capacity: capacity,
              count: 1,
              colors: colors,
            ),
          ],
        ),
      );
      final colors = [const Color3(1, 0, 0), const Color3(0, 1, 0)];
      await tester.pumpWidget(scene(2, colors));
      final mesh = ref.require;
      colors[0] = const Color3(0, 0, 1);
      await tester.pumpWidget(scene(2, colors));
      expect(ref.require, same(mesh));
      expect(mesh.getColor(0), const Color3(0, 0, 1));
      await tester.pumpWidget(scene(2, []));
      expect(mesh.getColor(0), const Color3(1, 1, 1));
      await tester.pumpWidget(scene(3, []));
      expect(ref.require, isNot(same(mesh)));
      expect(mesh.parent, isNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );
  testWidgets(
    'model mixer advances native deformation pose, pauses and releases on removal',
    (tester) async {
      final asset = (await tester.runAsync(() => load(animatedModel())))!;
      final instance = asset.instantiate();
      final backend = AnimationReferenceBackend();
      final r = runtime(backend);
      AnimationAction? action;
      late SceneController animationController;
      Widget scene({
        bool paused = false,
        bool mounted = true,
        String name = 'move',
      }) => host(
        SceneCanvas(
          runtime: r,
          options: readback,
          onCreated: (value) => animationController = value,
          children: [
            ObjectNode(
              object: instance,
              children: [
                if (mounted)
                  ModelAnimationNode(
                    instance: instance,
                    clipName: name,
                    paused: paused,
                    onAction: (value) => action = value,
                  ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpWidget(scene());
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(
        animationController.status.value,
        isA<SceneReady>(),
        reason: animationController.status.value is SceneFailed
            ? (animationController.status.value as SceneFailed).issue.toString()
            : animationController.status.value.toString(),
      );
      expect(
        instance.nodes[1]!.position.x,
        greaterThan(0),
        reason:
            'time=${action?.time} submits=${backend.submissions.length} plugins=${animationController.state.value.pluginIds}',
      );
      expect(action!.isPlaying, isTrue);
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final deformation = mesh.captureDeformation()!;
      expect(deformation.matrices, isNotEmpty);
      expect(deformation.weights.single, greaterThan(0));
      expect(mesh.geometry.positions.first, -1);
      await tester.pumpWidget(scene(paused: true));
      await frames(tester);
      final position = instance.nodes[1]!.position;
      final idle = backend.submissions.length;
      await frames(tester);
      expect(instance.nodes[1]!.position, position);
      expect(backend.submissions.length, idle);
      await tester.pumpWidget(scene(mounted: false));
      await frames(tester);
      expect(action!.isStopped, isTrue);
      expect(instance.mixer.actions, isEmpty);
      await tester.pumpWidget(scene(name: 'missing'));
      expect(tester.takeException(), isArgumentError);
      await tester.pumpWidget(scene());
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(instance.mixer.actions.length, 1);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(instance.mixer.actions, isEmpty);
    },
  );
  testWidgets(
    'two instances share an asset and animate independently in one canvas',
    (tester) async {
      final asset = (await tester.runAsync(() => load(animatedModel())))!;
      final first = asset.instantiate(), second = asset.instantiate();
      final backend = AnimationReferenceBackend();
      // Keep one native session while changing only the first action's pause state.
      final r = runtime(backend);
      Widget scene(bool pauseFirst) => host(
        SceneCanvas(
          runtime: r,
          options: readback,
          children: [
            ObjectNode(
              object: first,
              children: [
                ModelAnimationNode(instance: first, paused: pauseFirst),
              ],
            ),
            ObjectNode(
              object: second,
              children: [ModelAnimationNode(instance: second, speed: 2)],
            ),
          ],
        ),
      );
      await tester.pumpWidget(scene(false));
      await frames(tester);
      expect(first.mixer.id, isNot(second.mixer.id));
      expect(first.mixer.actions.single.time, greaterThan(Duration.zero));
      expect(
        second.mixer.actions.single.time,
        greaterThan(first.mixer.actions.single.time),
      );
      expect(first.nodes[1], isNot(same(second.nodes[1])));
      await tester.pumpWidget(scene(true));
      await frames(tester);
      final pausedPosition = first.nodes[1]!.position;
      final secondTime = second.mixer.actions.single.time;
      await frames(tester);
      expect(first.nodes[1]!.position, pausedPosition);
      expect(second.mixer.actions.single.time, isNot(secondTime));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(first.mixer.actions, isEmpty);
      expect(second.mixer.actions, isEmpty);
    },
  );
  testWidgets(
    'a competing animation action fails and recovers after stop and retry',
    (tester) async {
      final asset = (await tester.runAsync(() => load(animatedModel())))!;
      final instance = asset.instantiate();
      final backend = AnimationReferenceBackend();
      late SceneController controller;
      await tester.pumpWidget(
        host(
          SceneCanvas(
            runtime: runtime(backend),
            options: readback,
            onCreated: (value) => controller = value,
            children: [
              ObjectNode(
                object: instance,
                children: [ModelAnimationNode(instance: instance)],
              ),
            ],
          ),
        ),
      );
      await frames(tester);
      final extra = instance.mixer.play(instance.animations.single);
      await frames(tester);
      expect(controller.status.value, isA<SceneFailed>());
      expect(
        (controller.status.value as SceneFailed).issue.message,
        contains('playback owner'),
      );
      extra.stop();
      expect(instance.mixer.actions, hasLength(1));
      final owned = instance.mixer.actions.single;
      final beforeRetry = owned.time;
      await controller.retry();
      await frames(tester);
      expect(controller.status.value, isA<SceneReady>());
      expect(instance.mixer.actions.single, same(owned));
      expect(owned.time, isNot(beforeRetry));
      expect(instance.mixer.isAdvancing, isTrue);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(instance.mixer.actions, isEmpty);
    },
  );
  testWidgets(
    'environment and effects attach real resource and graph paths and dispose',
    (tester) async {
      final backend = RenderingBackend();
      final r = SceneRuntime(
        backendFactory: () async => backend,
        presenterFactory: () => TestPresenter('reference', []),
      );
      late SceneController controller;
      EnvironmentLighting? environment;
      PostProcessing? effects;
      final panorama = fixture.image(1), pipeline = ColorPipeline();
      Widget scene(double intensity, {bool enabled = true, bool aa = false}) =>
          host(
            SceneCanvas(
              runtime: r,
              options: readback,
              colorPipeline: pipeline,
              onCreated: (c) => controller = c,
              children: [
                EnvironmentLightingNode(
                  image: panorama,
                  quality: fixture.quality,
                  intensity: intensity,
                  enabled: enabled,
                  onPlugin: (p) => environment = p,
                ),
                PostProcessingNode(
                  bloom: BloomOptions(),
                  antialias: aa,
                  enabled: enabled,
                  onPlugin: (p) => effects = p,
                ),
              ],
            ),
          );
      await tester.pumpWidget(scene(1));
      await frames(tester);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await frames(tester);
      expect(controller.pluginIssue, isNull);
      expect(
        controller.status.value,
        isA<SceneReady>(),
        reason: controller.status.value is SceneFailed
            ? (controller.status.value as SceneFailed).issue.toString()
            : controller.status.value.toString(),
      );
      expect(environment!.map, isNotNull);
      expect(backend.device.references, isNotEmpty);
      expect(backend.device.builds, greaterThan(0));
      final old = environment, oldEffects = effects;
      await tester.pumpWidget(scene(2, aa: true));
      await frames(tester);
      expect(environment, same(old));
      expect(effects, same(oldEffects));
      expect(environment!.intensity, 2);
      expect(effects!.antialias, isTrue);
      await tester.pumpWidget(scene(2, enabled: false));
      await frames(tester);
      expect(environment!.map, isNull);
      await tester.pumpWidget(scene(2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await frames(tester);
      expect(environment!.map, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      await tester.runAsync(() async {
        await controller.whenDisposed;
      });
      expect(backend.device.references, isEmpty);
      expect(backend.device.programs, isEmpty);
      expect(backend.device.graphs, isEmpty);
    },
  );
}
