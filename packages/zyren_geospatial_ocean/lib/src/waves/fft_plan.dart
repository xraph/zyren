import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

final class OceanFftStage {
  final int halfWidth, axis;
  final bool normalize;
  const OceanFftStage(this.halfWidth, this.axis, this.normalize);

  /// CPU stage fixture. The numerical oracle remains independent in reference.dart.
  Float64List apply(Float64List input, int size) {
    OceanFftPlan(size);
    if (input.length != size * size * 2 ||
        halfWidth < 1 ||
        halfWidth >= size ||
        (halfWidth & (halfWidth - 1)) != 0 ||
        (axis != 0 && axis != 1)) {
      throw ArgumentError('Invalid Stockham stage.');
    }
    final output = Float64List(input.length);
    int address(int f, int line) =>
        2 * (axis == 0 ? line * size + f : f * size + line);
    for (var line = 0; line < size; line++) {
      for (var j = 0; j < size ~/ 2; j++) {
        final k = j % halfWidth,
            a = address(j, line),
            b = address(j + size ~/ 2, line);
        final angle = 2 * math.pi * k / (2 * halfWidth),
            c = math.cos(angle),
            s = math.sin(angle);
        final r = input[b] * c - input[b + 1] * s,
            im = input[b] * s + input[b + 1] * c;
        final first = address(2 * j - k, line),
            second = address(2 * j - k + halfWidth, line);
        final scale = normalize ? 1 / (size * size) : 1.0;
        output[first] = (input[a] + r) * scale;
        output[first + 1] = (input[a + 1] + im) * scale;
        output[second] = (input[a] - r) * scale;
        output[second + 1] = (input[a + 1] - im) * scale;
      }
    }
    return output;
  }
}

final class OceanFftPlan {
  final int size;
  late final List<OceanFftStage> stages = List.unmodifiable([
    for (var axis = 0; axis < 2; axis++)
      for (var half = 1; half < size; half *= 2)
        OceanFftStage(half, axis, axis == 1 && half == size ~/ 2),
  ]);
  OceanFftPlan(this.size) {
    if (size < 4 || size > 512 || (size & (size - 1)) != 0) {
      throw ArgumentError('Invalid FFT size.');
    }
  }
  Future<List<ComputePassDescriptor>> build(
    GpuScope scope,
    ShaderProgram shader,
    GpuResource<Buffer> first,
    GpuResource<Buffer> second, {
    int channels = 1,
    String prefix = 'ocean-fft',
  }) async {
    if (channels < 1 ||
        channels > 6 ||
        identical(first, second) ||
        first.descriptor.byteLength < channels * size * size * 8 ||
        second.descriptor.byteLength < channels * size * size * 8) {
      throw ArgumentError('Invalid FFT buffers.');
    }
    final passes = <ComputePassDescriptor>[];
    var source = first, target = second;
    for (var i = 0; i < stages.length; i++) {
      final stage = stages[i];
      final config = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 16,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      await scope.resources.writeBuffer(
        config,
        Uint32List.fromList([
          size,
          stage.halfWidth,
          stage.axis,
          stage.normalize ? 1 : 0,
        ]),
      );
      passes.add(
        ComputePassDescriptor(
          name: '$prefix-$i',
          program: shader,
          workgroups: Workgroups(
            (size ~/ 2 + 7) ~/ 8,
            (size + 7) ~/ 8,
            channels,
          ),
          reads: [config, source, target],
          writes: [target],
          bindings: ShaderBindings([
            BufferBinding.uniform(0, config),
            BufferBinding.storageRead(1, source),
            BufferBinding.storageReadWrite(2, target),
          ]),
        ),
      );
      final previous = source;
      source = target;
      target = previous;
    }
    return List.unmodifiable(passes);
  }
}
