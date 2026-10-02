import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'blur_wgsl.dart';

enum BlurKind { gaussian, kawase, mipmap, surface }

/// Source Pascal kernel with paired taps for bilinear sampling.
final class GaussianKernel {
  final List<double> weights, offsets;
  GaussianKernel._(this.weights, this.offsets);
  factory GaussianKernel(int size) {
    if (size < 3 || size > 63 || size.isEven) {
      throw ArgumentError.value(size, 'size');
    }
    var row = <double>[1];
    for (var i = 1; i < size + 4; i++) {
      row = [1, for (var j = 1; j < row.length; j++) row[j - 1] + row[j], 1];
    }
    final coefficients = row.sublist(2, row.length - 2), mid = (size - 1) ~/ 2;
    final sum = coefficients.fold<double>(0, (a, b) => a + b);
    final weights = List<double>.filled((mid + 1) ~/ 2, 0),
        offsets = List<double>.filled((mid + 1) ~/ 2, 0);
    weights[0] = coefficients[mid] / sum;
    // The source typed array discards a final pair beyond its allocated length.
    for (var i = 1, j = 1; i < mid && j < weights.length; i += 2, j++) {
      final a = coefficients[mid + i], b = coefficients[mid + i + 1];
      weights[j] = (a + b) / sum;
      offsets[j] = (i * a + (i + 1) * b) / (a + b);
    }
    final total =
        weights[0] + 2 * weights.skip(1).fold<double>(0, (a, b) => a + b);
    return GaussianKernel._(
      List.unmodifiable(weights.map((v) => v / total)),
      List.unmodifiable(offsets),
    );
  }
}

/// A reusable compute blur with a retained input and immutable output extent.
/// Rebuild a candidate when its input dimensions or kernel settings change.
final class TextureBlur {
  final GpuScope _scope;
  final CompiledGraph _graph;
  final GpuResource<Texture> output;
  TextureBlur._(this._scope, this._graph, this.output);
  bool get isClosed => _scope.isClosed;
  Future<GraphStats> execute() => _graph.execute();
  Future<void> close() => _scope.close();

  static Future<TextureBlur> create(
    GpuScope owner,
    GpuResource<Texture> input, {
    BlurKind kind = BlurKind.gaussian,
    int kernelSize = 35,
    int levels = 4,
    double surfaceBlend = .85,
  }) async {
    final descriptor = input.descriptor as TextureDescriptor;
    if (input.isClosed) throw StateError('Blur input owner has closed.');
    if (descriptor.dimension != TextureDimension.d2 ||
        descriptor.width > 1024 ||
        descriptor.height > 1024 ||
        !descriptor.usage.contains(TextureUsage.sampled) ||
        levels < 2 ||
        levels > 8 ||
        !surfaceBlend.isFinite ||
        surfaceBlend < 0 ||
        surfaceBlend > 1) {
      throw ArgumentError('Invalid blur input or settings.');
    }
    final kernel = GaussianKernel(kernelSize);
    final scope = owner.createChild(label: '${kind.name} blur');
    try {
      final retained = await scope.resources.retain(input);
      var current = retained;
      final passes = <PassDescriptor>[], shaders = <String, ShaderProgram>{};
      Future<GpuResource<Texture>> pass(
        String mode,
        int width,
        int height, {
        GpuResource<Texture>? high,
      }) async {
        final source = current;
        final output = await scope.resources.createTexture(
          TextureDescriptor(
            width: width,
            height: height,
            format: TextureFormat.rgba16Float,
            usage: {
              TextureUsage.sampled,
              TextureUsage.storage,
              TextureUsage.copySource,
            },
          ),
        );
        final program = shaders[mode] ??= await scope.shaders.compile(
          ShaderSource.wgsl(
            blurShader(mode, kernel.weights, kernel.offsets, surfaceBlend),
            label: '${kind.name} $mode',
          ),
        );
        passes.add(
          ComputePassDescriptor(
            name: 'blur ${passes.length}',
            program: program,
            bindings: ShaderBindings([
              TextureBinding.sampled(0, source),
              if (high != null) TextureBinding.sampled(1, high),
              TextureBinding.storage(2, output),
            ]),
            reads: [source, ?high],
            writes: [output],
            workgroups: Workgroups((width + 7) ~/ 8, (height + 7) ~/ 8),
          ),
        );
        current = output;
        return output;
      }

      if (kind == BlurKind.gaussian) {
        await pass('horizontal', descriptor.width, descriptor.height);
        await pass('vertical', descriptor.width, descriptor.height);
      } else {
        var width = (descriptor.width * .5).round(),
            height = (descriptor.height * .5).round();
        final downs = <GpuResource<Texture>>[];
        for (var i = 0; i < levels; i++) {
          width = math.max(1, (width / 2).round());
          height = math.max(1, (height / 2).round());
          downs.add(await pass('${kind.name}Down', width, height));
        }
        for (var i = levels - 2; i >= 0; i--) {
          final extent = downs[i].descriptor as TextureDescriptor;
          await pass(
            '${kind.name}Up',
            extent.width,
            extent.height,
            high: kind == BlurKind.surface ? downs[i] : null,
          );
        }
      }
      final graph = await scope.graphs.compile(
        GraphDescription(
          label: '${kind.name} blur',
          inputs: [retained],
          passes: passes,
        ),
      );
      return TextureBlur._(scope, graph, current);
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}
