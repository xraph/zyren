import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'appearance.dart';
import 'frame.dart';
import 'parameters.dart';
import 'quality.dart';
import 'textures.dart';
import 'media_uniforms.dart';
import 'media_wgsl.dart';
import 'sampling_wgsl.dart';
import 'shadow_wgsl.dart';
import 'blue_noise_wgsl.dart';
import 'texture_source.dart';
import 'shadow_temporal.dart';

/// Internal owned shadow stage, shared with the following cloud screen producer.
final class CloudShadowPass {
  final GpuScope scope;
  final GpuResource<Buffer> media, frame, noise;
  final GpuResource<Texture>? rawAtlas;
  final CloudShadowTemporal? temporal;
  GpuResource<Texture>? get atlas => temporal?.output ?? rawAtlas;
  final CloudTextureSet textures;
  final CompiledGraph? graph;
  final CloudQuality quality;
  final int size;
  CloudShadowPass._(
    this.scope,
    this.media,
    this.frame,
    this.noise,
    this.rawAtlas,
    this.temporal,
    this.textures,
    this.graph,
    this.quality,
    this.size,
  );
  List<ShaderBinding> get bindings => [
    BufferBinding.uniform(0, media, group: 2),
    for (var i = 0; i < 4; i++)
      TextureBinding.sampled(
        i + 1,
        textures.textures.resources[i],
        group: 2,
        mipLevels:
            (textures.textures.resources[i].descriptor as TextureDescriptor)
                .mipLevels,
      ),
    ...cloudSamplingBindings(textures.textures),
    BufferBinding.uniform(5, frame, group: 2),
    BufferBinding.storageRead(7, noise, group: 2),
  ];
  static Future<CloudShadowPass> build(
    GpuScope owner,
    CloudTextures maps,
    CloudQuality quality, {
    int? mapSize,
    CloudBlueNoise? blueNoise,
    bool temporal = false,
  }) async {
    final size = mapSize ?? quality.shadow.mapSize.$1;
    RangeError.checkValueInInterval(size, 1, 1024, 'shadow map size');
    final scope = owner.createChild(label: 'cloud shadow pass');
    try {
      final textures = await maps.retain(scope);
      final media = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 400,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final frame = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 800,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final noise = await scope.resources.createBuffer(
        BufferDescriptor(
          size: blueNoise?.bytes.length ?? 4,
          usage: {BufferUsage.storage, BufferUsage.copyDestination},
        ),
      );
      await scope.resources.writeBuffer(
        noise,
        blueNoise?.bytes ?? Uint8List(4),
      );
      if (!quality.shadowsEnabled) {
        return CloudShadowPass._(
          scope,
          media,
          frame,
          noise,
          null,
          null,
          textures,
          null,
          quality,
          size,
        );
      }
      final atlas = await scope.resources.createTexture(
        TextureDescriptor(
          width: size * quality.shadow.cascadeCount,
          height: size,
          format: TextureFormat.rgba32Float,
          usage: {
            TextureUsage.sampled,
            TextureUsage.storage,
            TextureUsage.copySource,
          },
        ),
      );
      final program = await scope.shaders.compile(
        ShaderSource.wgsl(
          cloudMediaMathWgsl(quality) +
              cloudFrameWgsl +
              cloudBlueNoiseWgsl +
              cloudSamplingShader(maps) +
              cloudShadowMarchWgsl(quality) +
              cloudShadowComputeWgsl(quality.shadow.cascadeCount),
          label: 'cloud Beer shadows',
        ),
      );
      final inputs = <GpuResource>[
        media,
        frame,
        noise,
        ...textures.textures.resources,
      ];
      final graph = await scope.graphs.compile(
        GraphDescription(
          inputs: inputs,
          passes: [
            ComputePassDescriptor(
              name: 'cloud Beer shadows',
              program: program,
              bindings: ShaderBindings([
                BufferBinding.uniform(0, media, group: 2),
                for (var i = 0; i < 4; i++)
                  TextureBinding.sampled(
                    i + 1,
                    textures.textures.resources[i],
                    group: 2,
                    mipLevels:
                        (textures.textures.resources[i].descriptor
                                as TextureDescriptor)
                            .mipLevels,
                  ),
                ...cloudSamplingBindings(maps),
                BufferBinding.uniform(5, frame, group: 2),
                BufferBinding.storageRead(7, noise, group: 2),
                TextureBinding.storage(0, atlas, group: 3),
              ]),
              reads: inputs,
              writes: [atlas],
              workgroups: Workgroups(
                (size * quality.shadow.cascadeCount + 7) ~/ 8,
                (size + 7) ~/ 8,
              ),
            ),
          ],
        ),
      );
      return CloudShadowPass._(
        scope,
        media,
        frame,
        noise,
        atlas,
        temporal
            ? await CloudShadowTemporal.build(
                scope,
                atlas,
                media,
                frame,
                quality,
              )
            : null,
        textures,
        graph,
        quality,
        size,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  Future<void> render(
    CloudParameters parameters,
    CloudAppearance appearance,
    CloudFrameState state, {
    double elapsed = 0,
    bool historyValid = false,
  }) async {
    if (quality.shadowsEnabled &&
        (state.cascades.cascades.length != quality.shadow.cascadeCount ||
            state.data[178] != size ||
            state.data[179] != size)) {
      throw ArgumentError('Cloud frame and shadow atlas dimensions differ.');
    }
    await scope.resources.writeBuffer(
      media,
      cloudMediaUniforms(parameters, appearance, elapsed: elapsed),
    );
    await scope.resources.writeBuffer(frame, state.data);
    await graph?.execute();
    await temporal?.render(state, valid: historyValid);
  }

  void presented() => temporal?.presented();
  Future<void> close() => scope.close();
}
