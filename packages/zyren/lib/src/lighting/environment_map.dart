part of '../resources/resource_scope.dart';

/// Resolution and integration cost for a prepared environment. Specular levels
/// encode uniformly spaced perceptual roughness and stop at 8 by 4 texels.
final class EnvironmentQuality {
  final int specularWidth, diffuseWidth, brdfSize, samples;
  const EnvironmentQuality({
    this.specularWidth = 256,
    this.diffuseWidth = 64,
    this.brdfSize = 128,
    this.samples = 256,
  });
  int get specularMipLevels => specularWidth.bitLength - 3;
  void validate() {
    for (final (value, upper, name) in [
      (specularWidth, 1024, 'specularWidth'),
      (diffuseWidth, 256, 'diffuseWidth'),
      (brdfSize, 512, 'brdfSize'),
    ]) {
      RangeError.checkValueInInterval(value, 16, upper, name);
      if ((value & (value - 1)) != 0) {
        throw ArgumentError.value(value, name, 'Use a power of two.');
      }
    }
    RangeError.checkValueInInterval(samples, 64, 2048, 'samples');
    var texels = diffuseWidth * diffuseWidth ~/ 2 + brdfSize * brdfSize;
    for (var i = 1; i < specularMipLevels; i++) {
      final width = specularWidth >> i;
      texels += width * width ~/ 2;
    }
    if (texels * samples > 256 * 1024 * 1024) {
      throw ArgumentError(
        'Environment integration exceeds 256 million samples.',
      );
    }
  }
}

/// Device-owned diffuse radiance, GGX-prefiltered specular radiance and a
/// correlated-Smith BRDF lookup. All textures use linear RGBA16F storage.
/// Diffuse stores irradiance divided by pi. BRDF R/G store Schlick A/B; A+B is
/// white directional energy. Axes include NdotV and roughness endpoints, so texel
/// (x,y) represents (x/(width-1), y/(height-1)). Sample at remapped texel centers.
final class EnvironmentMap {
  final ResourceScope _scope;
  final GpuResource<Texture> diffuse, specular, brdf;
  final EnvironmentQuality quality;
  EnvironmentMap._(
    this._scope,
    this.diffuse,
    this.specular,
    this.brdf,
    this.quality,
  );
  static int retainedPayloadBytes(Iterable<EnvironmentMap> maps) {
    final textures = <Object, GpuResource<Texture>>{};
    for (final map in maps) {
      for (final t in [map.diffuse, map.specular, map.brdf]) {
        textures[t._key] = t;
      }
    }
    return textures.values.fold(0, (n, t) => n + t.descriptor.byteLength);
  }

  bool get isClosed => _scope.isClosed;
  Future<void> close() => _scope.close();

  /// Prepares a top-down equirectangular image. +Y is at the top, +X at u=.5,
  /// +Z at u=.75. RGB defines radiance; image alpha is ignored.
  static Future<EnvironmentMap> fromEquirectangular(
    HdrImageData image, {
    required ResourceScope resources,
    EnvironmentQuality quality = const EnvironmentQuality(),
  }) => resources._run(() async {
    quality.validate();
    if (image.size.width != image.size.height * 2) {
      throw ArgumentError('Equirectangular images require a 2:1 extent.');
    }
    final temporary = resources.createChild(label: 'environment source');
    EnvironmentMap? prepared;
    try {
      final source = await temporary.createTexture(
        TextureDescriptor(
          label: 'HDR environment source',
          width: image.size.width,
          height: image.size.height,
          mipLevels: image.size.width.bitLength,
          format: TextureFormat.rgba16Float,
          usage: {
            TextureUsage.sampled,
            TextureUsage.copyDestination,
            TextureUsage.renderAttachment,
          },
        ),
      );
      final pixels = await Isolate.run(
        image.toRgba16Float,
        debugName: 'zyren-environment-upload',
      );
      await temporary.writeTexture(source, pixels);
      await temporary.generateMipmaps(source);
      prepared = await prefilter(
        source,
        resources: resources,
        quality: quality,
      );
      return prepared;
    } finally {
      try {
        await temporary.close();
      } catch (error) {
        try {
          await prepared?.close();
        } catch (cleanupError) {
          throw ScopeCleanupException([error, cleanupError]);
        }
        rethrow;
      }
    }
  });

  /// Prepares a sampled RGBA16F equirectangular texture, including procedural
  /// sources. Source mips must already be initialized with finite nonnegative
  /// radiance. A complete mip chain improves filtering of small bright lights.
  static Future<EnvironmentMap> prefilter(
    GpuResource<Texture> source, {
    required ResourceScope resources,
    EnvironmentQuality quality = const EnvironmentQuality(),
    GpuResource<Texture>? reuseBrdf,
    Future<void> Function(int integrationSamples)? beforePass,
  }) => resources._run(() async {
    quality.validate();
    final descriptor = source.descriptor as TextureDescriptor;
    final device = resources._device;
    if (source.isClosed || !identical(source._scope._device, device)) {
      throw ArgumentError(
        'Environment source needs a live owner on this device.',
      );
    }
    if (device is! GraphDevice ||
        descriptor.format != TextureFormat.rgba16Float ||
        descriptor.width != descriptor.height * 2 ||
        !descriptor.usage.contains(TextureUsage.sampled)) {
      throw ArgumentError(
        'Environment preparation needs a graph device and sampled 2:1 RGBA16F source.',
      );
    }
    final output = resources.createChild(label: 'environment map');
    final temporary = resources.createChild(label: 'environment integration');
    final shaders = ShaderCompiler(device, label: 'environment integration');
    final graphs = GraphCompiler(device, label: 'environment integration');
    var delivered = false;
    try {
      final input = await temporary.retain(source);
      Future<GpuResource<Texture>> texture(
        String label,
        int width,
        int height, [
        int mipLevels = 1,
      ]) => output.createTexture(
        TextureDescriptor(
          label: label,
          width: width,
          height: height,
          mipLevels: mipLevels,
          format: TextureFormat.rgba16Float,
          usage: {
            TextureUsage.sampled,
            TextureUsage.storage,
            TextureUsage.copySource,
          },
        ),
      );
      final diffuse = await texture(
        'diffuse environment',
        quality.diffuseWidth,
        quality.diffuseWidth ~/ 2,
      );
      final specular = await texture(
        'specular environment',
        quality.specularWidth,
        quality.specularWidth ~/ 2,
        quality.specularMipLevels,
      );
      if (reuseBrdf != null) {
        final d = reuseBrdf.descriptor as TextureDescriptor;
        if (d.width != quality.brdfSize ||
            d.height != quality.brdfSize ||
            d.format != TextureFormat.rgba16Float ||
            d.mipLevels != 1 ||
            !d.usage.contains(TextureUsage.sampled)) {
          throw ArgumentError(
            'Reused BRDF must match the environment quality.',
          );
        }
      }
      final brdf = reuseBrdf == null
          ? await texture(
              'environment BRDF',
              quality.brdfSize,
              quality.brdfSize,
            )
          : await output.retain(reuseBrdf);
      final convolution = await shaders.compile(
        ShaderSource.wgsl(
          _environmentConvolution,
          label: 'environment convolution',
        ),
      );
      final lookup = await shaders.compile(
        ShaderSource.wgsl(_environmentBrdf, label: 'environment BRDF'),
      );
      final passes = <ComputePassDescriptor>[];
      Future<GpuResource<Buffer>> options(double roughness, int mode) async {
        final data = ByteData(16)
          ..setFloat32(0, roughness, Endian.little)
          ..setUint32(4, mode, Endian.little)
          ..setUint32(8, quality.samples, Endian.little);
        final buffer = await temporary.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        await temporary.writeBuffer(buffer, data);
        return buffer;
      }

      final inputs = <GpuResource<Object?>>[input];
      Future<void> convolve(
        String name,
        GpuResource<Texture> target,
        int mip,
        double roughness,
        int mode,
      ) async {
        final params = await options(roughness, mode);
        inputs.add(params);
        final targetDescriptor = target.descriptor as TextureDescriptor;
        passes.add(
          ComputePassDescriptor(
            name: name,
            program: convolution,
            workgroups: Workgroups(
              ((targetDescriptor.width >> mip) + 7) ~/ 8,
              ((targetDescriptor.height >> mip) + 7) ~/ 8,
            ),
            after: passes.isEmpty ? {} : {passes.last.name},
            reads: [input, params],
            writes: [target],
            bindings: ShaderBindings([
              TextureBinding.sampled(0, input, mipLevels: descriptor.mipLevels),
              SamplerBinding(
                1,
                sampler: const SamplerDescriptor(wrapU: TextureWrap.repeat),
              ),
              TextureBinding.storage(2, target, mipLevel: mip),
              BufferBinding.uniform(3, params),
            ]),
          ),
        );
      }

      await convolve('diffuse', diffuse, 0, 1, 0);
      for (var i = 0; i < quality.specularMipLevels; i++) {
        await convolve(
          'specular-$i',
          specular,
          i,
          i / (quality.specularMipLevels - 1),
          1,
        );
      }
      final params = await options(0, 0);
      inputs.add(params);
      if (reuseBrdf == null) {
        passes.add(
          ComputePassDescriptor(
            name: 'BRDF',
            program: lookup,
            workgroups: Workgroups(
              (quality.brdfSize + 7) ~/ 8,
              (quality.brdfSize + 7) ~/ 8,
            ),
            reads: [params],
            writes: [brdf],
            bindings: ShaderBindings([
              TextureBinding.storage(0, brdf),
              BufferBinding.uniform(1, params),
            ]),
          ),
        );
      }
      if (beforePass == null) {
        final graph = await graphs.compile(
          GraphDescription(
            label: 'environment integration',
            inputs: inputs,
            passes: passes,
          ),
        );
        await graph.execute();
      } else {
        for (final pass in passes) {
          // Each job owns a graph so callers can admit one actual dispatch.
          final job = ComputePassDescriptor(
            name: pass.name,
            program: pass.program,
            workgroups: pass.workgroups,
            reads: pass.reads,
            writes: pass.writes,
            bindings: pass.bindings,
          );
          final target = pass.writes.single.descriptor as TextureDescriptor;
          final level = pass.name.startsWith('specular-')
              ? int.parse(pass.name.substring(9))
              : 0;
          await beforePass(
            (target.width >> level) *
                (target.height >> level) *
                quality.samples,
          );
          final graph = await graphs.compile(
            GraphDescription(
              label: 'environment integration step',
              inputs: inputs,
              passes: [job],
            ),
          );
          try {
            await graph.execute();
          } finally {
            await graph.close();
          }
        }
      }
      if (output.isClosed) {
        throw StateError('Environment owner closed during preparation.');
      }
      delivered = true;
      return EnvironmentMap._(output, diffuse, specular, brdf, quality);
    } finally {
      final errors = <Object>[];
      for (final close in [graphs.close, shaders.close, temporary.close]) {
        try {
          await close();
        } catch (error) {
          errors.add(error);
        }
      }
      if (!delivered || errors.isNotEmpty) {
        try {
          await output.close();
        } catch (error) {
          errors.add(error);
        }
      }
      if (errors.isNotEmpty) throw ScopeCleanupException(errors);
    }
  });

  /// Keeps the prepared textures in another scope on the same native device.
  Future<EnvironmentMap> retain(ResourceScope resources) =>
      _scope._run(() async {
        final owner = resources.createChild(label: 'retained environment');
        try {
          return EnvironmentMap._(
            owner,
            await owner.retain(diffuse),
            await owner.retain(specular),
            await owner.retain(brdf),
            quality,
          );
        } catch (_) {
          await owner.close();
          rethrow;
        }
      });

  /// Adapter contract. Texture keys stay alive until an accepted frame settles.
  Future<T> submitFrame<T>(
    ResourceDevice device,
    Future<T> Function(List<Object> keys) submit,
  ) => _scope._run(() {
    if (!identical(device, _scope._device)) {
      throw ArgumentError('Environment belongs to another native device.');
    }
    return submit([diffuse._key, specular._key, brdf._key]);
  });
}
