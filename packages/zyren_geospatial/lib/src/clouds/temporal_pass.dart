import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../atmosphere/cloud_inputs.dart';
import 'history.dart';
import 'temporal_wgsl.dart';

/// Stable scratch resolve and history publication for retained scene graphs.
final class CloudTemporalPass {
  final GpuScope scope;
  final GpuResource<Buffer> uniform;
  final AtmosphereCloudInputs outputs;
  final ScreenEffect resolve, publish;
  final int width, height, rawWidth, rawHeight;

  CloudTemporalPass._(
    this.scope,
    this.uniform,
    this.outputs,
    this.resolve,
    this.publish,
    this.width,
    this.height,
    this.rawWidth,
    this.rawHeight,
  );
  static Future<CloudTemporalPass> build(
    GpuScope owner,
    AtmosphereCloudInputs raw,
    int width,
    int height,
  ) async {
    final scope = owner.createChild(label: 'cloud temporal history');
    try {
      final uniform = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 48,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      Future<GpuResource<Texture>> target(TextureFormat format) =>
          scope.resources.createTexture(
            TextureDescriptor(
              width: width,
              height: height,
              format: format,
              usage: {
                TextureUsage.sampled,
                TextureUsage.storage,
                TextureUsage.copySource,
                if (format == TextureFormat.rgba16Float)
                  TextureUsage.renderAttachment,
              },
            ),
          );
      final color = await target(TextureFormat.rgba16Float);
      final data = await target(TextureFormat.rgba32Float);
      final historyData = await target(TextureFormat.rgba32Float);
      final outputs = AtmosphereCloudInputs(
        color: await target(TextureFormat.rgba16Float),
        depthVelocityShadow: await target(TextureFormat.rgba32Float),
        transmittance: await target(TextureFormat.r32Float),
      );
      final resolveShader = await scope.shaders.compile(
        ShaderSource.wgsl(
          PostProcessDescriptor.interfaceWgsl +
              cloudTemporalUniformWgsl +
              cloudVarianceWgsl +
              cloudResolveWgsl,
          label: 'cloud temporal resolve',
        ),
      );
      final publishShader = await scope.shaders.compile(
        ShaderSource.wgsl(
          PostProcessDescriptor.interfaceWgsl +
              cloudTemporalUniformWgsl +
              cloudPublishWgsl,
          label: 'cloud history publication',
        ),
      );
      final resolve = await scope.materials.compileEffect(
        PostProcessDescriptor(
          program: resolveShader,
          target: color,
          bindings: ShaderBindings([
            BufferBinding.uniform(8, uniform, group: 2),
            TextureBinding.sampled(0, raw.color, group: 1),
            TextureBinding.sampled(1, raw.depthVelocityShadow, group: 1),
            TextureBinding.sampled(2, outputs.color, group: 1),
            TextureBinding.sampled(3, historyData, group: 1),
            TextureBinding.sampled(4, raw.transmittance, group: 1),
            TextureBinding.storage(1, data, group: 3),
          ]),
        ),
      );
      final publish = await scope.materials.compileEffect(
        PostProcessDescriptor(
          program: publishShader,
          target: outputs.color,
          bindings: ShaderBindings([
            TextureBinding.sampled(0, color, group: 1),
            TextureBinding.sampled(1, data, group: 1),
            TextureBinding.sampled(2, raw.depthVelocityShadow, group: 1),
            BufferBinding.uniform(8, uniform, group: 2),
            TextureBinding.storage(1, outputs.depthVelocityShadow, group: 3),
            TextureBinding.storage(2, outputs.transmittance, group: 3),
            TextureBinding.storage(3, historyData, group: 3),
          ]),
        ),
      );
      final size = raw.color.descriptor as TextureDescriptor;
      return CloudTemporalPass._(
        scope,
        uniform,
        outputs,
        resolve,
        publish,
        width,
        height,
        size.width,
        size.height,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  Future<void> prepare(
    CloudHistoryFrame frame,
    CloudTemporalSettings settings, {
    int rayStride = 4,
  }) async {
    if (rayStride != 1 && rayStride != 4 && rayStride != 8) {
      throw ArgumentError.value(rayStride, 'rayStride');
    }
    const bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
    final phase = frame.number % 16, index = bayer.indexOf(phase);

    await scope.resources.writeBuffer(
      uniform,
      Float32List.fromList([
        width.toDouble(),
        height.toDouble(),
        (settings.mode == CloudTemporalMode.upscale
                ? (width + rayStride - 1) ~/ rayStride
                : rawWidth)
            .toDouble(),
        (settings.mode == CloudTemporalMode.upscale
                ? (height + rayStride - 1) ~/ rayStride
                : rawHeight)
            .toDouble(),
        frame.valid ? 1 : 0,
        phase.toDouble(),
        settings.alpha,
        settings.varianceGamma,
        (index % 4) * rayStride / 4,
        (index ~/ 4) * rayStride / 4,
        settings.mode.index.toDouble(),
        rayStride.toDouble(),
      ]),
    );
  }
}
