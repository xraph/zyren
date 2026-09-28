part of '../resources/resource_scope.dart';

final class Workgroups {
  final int x, y, z;
  const Workgroups(this.x, [this.y = 1, this.z = 1]);
}

enum AttachmentLoad { clear, load }

enum AttachmentStore { store, discard }

/// Procedural pass output is linear. Alpha blending expects premultiplied RGB;
/// additive blending sums RGB and alpha, while replace overwrites the target.
enum RenderBlend { replace, premultipliedAlpha, additive }

/// Linear RGBA. The target texture's format handles output color encoding.
final class ClearColor {
  final double red, green, blue, alpha;
  const ClearColor(this.red, this.green, this.blue, [this.alpha = 1]);
}

final class ColorAttachment {
  final GpuResource<Texture> texture;
  final int mipLevel;
  final AttachmentLoad load;
  final AttachmentStore store;
  final ClearColor clearColor;
  ColorAttachment(
    this.texture, {
    this.mipLevel = 0,
    this.load = AttachmentLoad.clear,
    this.store = AttachmentStore.store,
    this.clearColor = const ClearColor(0, 0, 0, 0),
  });
}

sealed class PassDescriptor {
  final String name;
  final ShaderProgram program;
  final ShaderBindings bindings;
  final List<GpuResource<Object?>> reads, writes;
  final Set<String> after;
  PassDescriptor({
    required this.name,
    required this.program,
    ShaderBindings? bindings,
    Iterable<GpuResource<Object?>> reads = const [],
    Iterable<GpuResource<Object?>> writes = const [],
    Set<String> after = const {},
  }) : bindings = bindings ?? ShaderBindings(const []),
       reads = List.unmodifiable(reads),
       writes = List.unmodifiable(writes),
       after = Set.unmodifiable(after);
}

final class ComputePassDescriptor extends PassDescriptor {
  final String entryPoint;
  final Workgroups workgroups;
  ComputePassDescriptor({
    required super.name,
    required super.program,
    required this.workgroups,
    this.entryPoint = 'main',
    super.bindings,
    super.reads,
    super.writes,
    super.after,
  });
}

/// Procedural draws use vertex_index and instance_index with no vertex buffers.
final class RenderPassDescriptor extends PassDescriptor {
  final String vertexEntryPoint, fragmentEntryPoint;
  final ColorAttachment color;
  final RenderBlend blend;
  final int vertexCount, instanceCount, sampleCount;
  RenderPassDescriptor({
    required super.name,
    required super.program,
    required this.color,
    this.blend = RenderBlend.replace,
    this.vertexEntryPoint = 'vertex',
    this.fragmentEntryPoint = 'fragment',
    this.vertexCount = 3,
    this.instanceCount = 1,
    this.sampleCount = 1,
    super.bindings,
    super.reads,
    super.writes,
    super.after,
  });
}
