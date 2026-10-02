import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../atmosphere/cloud_inputs.dart';
import 'history.dart';
import 'temporal_wgsl.dart';

/// Retained ping-pong history with a stable published set for atmosphere inputs.
final class CloudTemporalPass {
  final GpuScope scope;
  final GpuResource<Buffer> uniform;
  final AtmosphereCloudInputs outputs;
  final List<ScreenEffect> resolve, publish;
  final int width, height, rawWidth, rawHeight;
  int _history = 1, _pending = 0;
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
  int get pending => _pending;
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
      final colors = [
        await target(TextureFormat.rgba16Float),
        await target(TextureFormat.rgba16Float),
      ];
      final data = [
        await target(TextureFormat.rgba32Float),
        await target(TextureFormat.rgba32Float),
      ];
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
      final resolve = <ScreenEffect>[], publish = <ScreenEffect>[];
      for (var i = 0; i < 2; i++) {
        resolve.add(
          await scope.materials.compileEffect(
            PostProcessDescriptor(
              program: resolveShader,
              target: colors[i],
              bindings: ShaderBindings([
                BufferBinding.uniform(8, uniform, group: 2),
                TextureBinding.sampled(0, raw.color, group: 1),
                TextureBinding.sampled(1, raw.depthVelocityShadow, group: 1),
                TextureBinding.sampled(2, colors[1 - i], group: 1),
                TextureBinding.sampled(3, data[1 - i], group: 1),
                TextureBinding.sampled(4, raw.transmittance, group: 1),
                TextureBinding.storage(1, data[i], group: 3),
              ]),
            ),
          ),
        );
        publish.add(
          await scope.materials.compileEffect(
            PostProcessDescriptor(
              program: publishShader,
              target: outputs.color,
              bindings: ShaderBindings([
                TextureBinding.sampled(0, colors[i], group: 1),
                TextureBinding.sampled(1, data[i], group: 1),
                TextureBinding.sampled(2, raw.depthVelocityShadow, group: 1),
                BufferBinding.uniform(8, uniform, group: 2),
                TextureBinding.storage(
                  1,
                  outputs.depthVelocityShadow,
                  group: 3,
                ),
                TextureBinding.storage(2, outputs.transmittance, group: 3),
              ]),
            ),
          ),
        );
      }
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
    CloudTemporalSettings settings,
  ) async {
    const bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
    final phase = frame.number % 16, index = bayer.indexOf(phase);
    _pending = frame.valid ? 1 - _history : 0;
    await scope.resources.writeBuffer(
      uniform,
      Float32List.fromList([
        width.toDouble(),
        height.toDouble(),
        rawWidth.toDouble(),
        rawHeight.toDouble(),
        frame.valid ? 1 : 0,
        phase.toDouble(),
        settings.alpha,
        settings.varianceGamma,
        (index % 4).toDouble(),
        (index ~/ 4).toDouble(),
        settings.mode.index.toDouble(),
        0,
      ]),
    );
  }

  void presented() {
    _history = _pending;
  }
}
