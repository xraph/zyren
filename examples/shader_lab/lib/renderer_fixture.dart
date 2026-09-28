import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

/// A public-API consumer combining physical materials, shadows and instances.
final class RendererFixture {
  final scene = Scene()..background = const Color3(.018, .025, .045);
  final camera = PerspectiveCamera(
    position: const Vec3(6, 5, 8),
    target: const Vec3(0, .3, 0),
    near: .1,
    far: 30,
  );
  late final InstancedMesh instances;
  RendererFixture() {
    scene.add(
      Mesh(
        PlaneGeometry(width: 10, height: 8),
        StandardMaterial(
          baseColor: const Color3(.32, .36, .42),
          roughness: .85,
        ),
      )..rotateX(-math.pi / 2),
    );
    for (var row = 0; row < 2; row++) {
      for (var col = 0; col < 4; col++) {
        scene.add(
          Mesh(
              SphereGeometry(radius: .5, widthSegments: 32, heightSegments: 24),
              StandardMaterial(
                baseColor: row == 0
                    ? const Color3(.8, .25, .06)
                    : const Color3(.7, .72, .78),
                metallic: row.toDouble(),
                roughness: .1 + col * .28,
              ),
              name: '${row == 0 ? 'Dielectric' : 'Metal'} ${col + 1}',
            )
            ..position = Vec3((col - 1.5) * 1.4, .52, (row - .5) * 1.6)
            ..castShadow = true,
        );
      }
    }
    instances = scene.add(
      InstancedMesh(
        BoxGeometry(),
        StandardMaterial(
          baseColor: const Color3(.1, .5, .7),
          metallic: .6,
          roughness: .3,
        ),
        count: 64,
        name: 'Instances',
      )..castShadow = true,
    );
    for (var i = 0; i < instances.count; i++) {
      instances.setTransform(
        i,
        Mat4.compose(
          Vec3((i % 16 - 7.5) * .4, .16, -2.2 - i ~/ 16 * .4),
          Quat.identity,
          Vec3(i.isEven ? .2 : -.2, .3, .2),
        ),
      );
    }
    scene.add(
      Mesh(
        SphereGeometry(radius: .2, widthSegments: 24, heightSegments: 16),
        StandardMaterial(
          baseColor: const Color3(0, 0, 0),
          emissive: const Color3(1, .2, .025),
          emissiveIntensity: 8,
        ),
        name: 'Emitter',
      )..position = const Vec3(-3, .5, 1),
    );
    scene.add(
      DirectionalLight(
        direction: const Vec3(-1, -2, -1),
        intensity: 3,
        shadow: ShadowSettings(resolution: 512, cascades: 2, maxDistance: 25),
      ),
    );
    scene.add(
      SpotLight(
        direction: const Vec3(0, -1, 0),
        color: const Color3(.2, .5, 1),
        intensity: 18,
        range: 8,
        angle: .6,
        penumbra: .25,
        shadow: ShadowSettings(resolution: 256, maxDistance: 10),
      )..position = const Vec3(2, 3, 1),
    );
  }
  EnvironmentLightingPlugin environment() {
    final pixels = Float32List(16 * 8 * 4);
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 16; x++) {
        final offset = (y * 16 + x) * 4;
        final sky = y < 4 ? .25 : .04;
        final window = y < 3 && x >= 5 && x <= 7 ? 2.0 : 0.0;
        pixels.setRange(offset, offset + 4, [
          sky + window,
          sky * 1.1 + window,
          sky * 1.3 + window,
          1,
        ]);
      }
    }
    return EnvironmentLightingPlugin(
      EnvironmentImage(width: 16, height: 8, pixels: pixels),
      resolution: 16,
      roughnessLevels: 6,
      samples: 128,
      brdfSize: 32,
    );
  }
}

/// Chooses sample count from the adapter, without assuming an operating system.
final class RendererProfilePlugin extends ScenePlugin {
  @override
  String get id => 'renderer-profile';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.standardMaterials,
    RenderFeature.punctualLights,
    RenderFeature.environmentLighting,
    RenderFeature.shadowMaps,
    RenderFeature.instancing,
    RenderFeature.hdr,
    RenderFeature.spatialAntialiasing,
    RenderFeature.bloom,
  };
  @override
  void attach(PluginContext context) {
    context.scene.renderSettings = RenderSettings(
      sampleCount: context.capabilities.limits.sampleCounts.contains(4) ? 4 : 1,
      toneMapping: ToneMapping.aces,
      spatialAntialiasing: SpatialAntialiasing.fxaa,
      bloom: BloomSettings(intensity: .12),
    );
  }
}
