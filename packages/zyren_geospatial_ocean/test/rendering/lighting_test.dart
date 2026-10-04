import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'water uses native convolved HDR environments and atmosphere day/night',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea(wind: 0);
      final field = await OceanWaveFieldGpu.create(
        scope,
        oceanChartSeaState(state, 4),
      );
      final patch = OceanPatchId(face: 4, level: 16, x: 32768, y: 32768);
      final origin = patch.point(.5, .5);
      final scene = Scene();
      final camera = OrthographicCamera(
        position: origin + const Vec3(0, 0, 3),
        target: origin,
        verticalSize: 4,
        near: .1,
        far: 20,
      );
      Future<List<int>> draw() async {
        final result =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(32, 32),
                    colorPipeline: ColorPipeline(
                      toneMapping: ToneMapping.linear,
                    ),
                  ),
                )
                as ReadbackOutput;
        final at = (16 * 32 + 16) * 4;
        return result.image.pixels.sublist(at, at + 3);
      }

      try {
        final waves = await OceanWaveRenderData.pack(
          scope,
          state: state,
          charts: {4: await field.evaluate(0, resolution: 8)},
        );
        final envScope = scope.createChild();
        final source = await envScope.resources.createTexture(
          TextureDescriptor(
            width: 8,
            height: 4,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await envScope.resources.writeTexture(
          source,
          Float32List.fromList([
            for (var i = 0; i < 32; i++) ...[.5, 1, 2, 1],
          ]).buffer.asUint8List(),
        );
        final environment = await VolumeEnvironmentMap.generate(
          resources: envScope.resources,
          shaders: envScope.shaders,
          graphs: envScope.graphs,
          source: source,
          resolution: 4,
          roughnessLevels: 4,
          samples: 32,
          brdfSize: 8,
        );
        final material = await OceanWaterMaterial.create(
          scope,
          waves: waves,
          patch: patch,
          geometrySpacingMetres: .1,
          optics: OceanOptics(
            absorptionPerMetre: Vec3.zero,
            scatteringPerMetre: Vec3.zero,
            roughness: .4,
          ),
          lighting: OceanLighting(
            environment: environment,
            sunIrradiance: Vec3.zero,
          ),
          reflections: OceanReflectionSettings(
            mode: OceanReflectionMode.environment,
          ),
        );
        final mesh = scene.add(
          Mesh(PlaneGeometry(width: 4, height: 4), material.material)
            ..position = origin,
        );
        final first = await draw();
        expect(first[0], inInclusiveRange(23, 28));
        expect(first[1], inInclusiveRange(36, 42));
        expect(first[2], inInclusiveRange(54, 61));
        final mediumOwner = scope.createChild();
        final mediumLight = await OceanMediumLighting.create(
          mediumOwner,
          OceanLighting(environment: environment),
        );
        final output = await mediumOwner.resources.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.storage, BufferUsage.copySource},
          ),
        );
        final program = await mediumOwner.shaders.compile(
          ShaderSource.wgsl('''
${mediumLight.wgsl}
@group(0) @binding(0) var<storage,read_write> sample:vec4<f32>;
@compute @workgroup_size(1) fn main(){
 sample=vec4(oceanMediumSky(vec3(0.,0.,1.),vec3(0.,0.,1.),vec3(0.),vec2(1.,0.)),1.);
}
'''),
        );
        final resources = [
          for (final binding in mediumLight.bindings)
            if (binding.resource != null) binding.resource!,
        ];
        final graph = await mediumOwner.graphs.compile(
          GraphDescription(
            inputs: [output, ...resources],
            passes: [
              ComputePassDescriptor(
                name: 'medium environment reference',
                program: program,
                workgroups: const Workgroups(1),
                reads: [output, ...resources],
                writes: [output],
                bindings: ShaderBindings([
                  BufferBinding.storageReadWrite(0, output),
                  ...mediumLight.bindings,
                ]),
              ),
            ],
          ),
        );
        await envScope.close();
        await graph.execute();
        final sampled = ByteData.sublistView(
          await mediumOwner.resources.readBuffer(output),
        );
        for (var c = 0; c < 3; c++) {
          expect(
            sampled.getFloat32(c * 4, Endian.little),
            closeTo([.5, 1, 2][c], .002),
          );
        }
        await mediumOwner.close();
        expect(await draw(), first);
        scene.remove(mesh);
        await material.close();

        final cache = AtmosphereLutCache(scope);
        final lease = await cache.acquire(
          parameters: AtmosphereParameters.legacy(),
        );
        final values = <int>[];
        for (final direction in [const Vec3(.5, .2, 1), const Vec3(0, 0, -1)]) {
          final material = await OceanWaterMaterial.create(
            scope,
            waves: waves,
            patch: patch,
            geometrySpacingMetres: .1,
            optics: OceanOptics(roughness: .2),
            lighting: OceanLighting(
              atmosphere: lease.luts,
              sunDirectionEcef: direction,
            ),
            reflections: OceanReflectionSettings(
              mode: OceanReflectionMode.environment,
            ),
          );
          final mesh = scene.add(
            Mesh(PlaneGeometry(width: 4, height: 4), material.material)
              ..position = origin,
          );
          final rgb = await draw();
          values.add(rgb.reduce((a, b) => a + b));
          scene.remove(mesh);
          await material.close();
        }
        expect(values[0], greaterThan(values[1] + 20));
        await lease.close();
        await cache.close();
        await waves.close();
      } finally {
        for (final child in scene.children.toList()) {
          scene.remove(child);
        }
        await scope.close();
        await draw();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
