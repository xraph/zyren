part of '../resources/resource_scope.dart';

/// A typed slot in a shader's explicit bind-group layout.
sealed class ShaderBinding {
  final int binding, group;
  final Set<ShaderStage>? visibility;
  ShaderBinding(this.binding, {this.group = 0, Set<ShaderStage>? visibility})
    : visibility = visibility == null ? null : Set.unmodifiable(visibility);
  GpuResource<Object?>? get resource;
  bool get _reads;
  bool get _writes;
  String get _kind;
}

enum BufferBindingAccess { uniform, storageRead, storageReadWrite }

final class BufferBinding extends ShaderBinding {
  @override
  final GpuResource<Buffer> resource;
  final BufferBindingAccess access;
  final int offset;
  final int? size;
  BufferBinding.uniform(
    super.binding,
    this.resource, {
    super.group,
    this.offset = 0,
    this.size,
    super.visibility,
  }) : access = BufferBindingAccess.uniform;
  BufferBinding.storageRead(
    super.binding,
    this.resource, {
    super.group,
    this.offset = 0,
    this.size,
    super.visibility,
  }) : access = BufferBindingAccess.storageRead;
  BufferBinding.storageReadWrite(
    super.binding,
    this.resource, {
    super.group,
    this.offset = 0,
    this.size,
    super.visibility,
  }) : access = BufferBindingAccess.storageReadWrite;
  @override
  bool get _reads => true;
  @override
  bool get _writes => access == BufferBindingAccess.storageReadWrite;
  @override
  String get _kind => access.name;
}

final class TextureBinding extends ShaderBinding {
  @override
  final GpuResource<Texture> resource;
  final bool storage;
  final int mipLevel, mipLevels;
  TextureBinding.sampled(
    super.binding,
    this.resource, {
    super.group,
    this.mipLevel = 0,
    this.mipLevels = 1,
    super.visibility,
  }) : storage = false;
  TextureBinding.storage(
    super.binding,
    this.resource, {
    super.group,
    this.mipLevel = 0,
    super.visibility,
  }) : storage = true,
       mipLevels = 1;
  @override
  bool get _reads => !storage;
  @override
  bool get _writes => storage;
  @override
  String get _kind => storage ? 'storageTexture' : 'sampled';
}

final class SamplerBinding extends ShaderBinding {
  final SamplerDescriptor sampler;
  SamplerBinding(
    super.binding, {
    super.group,
    this.sampler = const SamplerDescriptor(),
    super.visibility,
  });
  @override
  GpuResource<Object?>? get resource => null;
  @override
  bool get _reads => false;
  @override
  bool get _writes => false;
  @override
  String get _kind => 'sampler';
}

final class ShaderBindings {
  final List<ShaderBinding> entries;
  ShaderBindings(Iterable<ShaderBinding> entries)
    : entries = List.unmodifiable(entries);
}
