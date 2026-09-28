import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../plugins/attachment_scope.dart';
import '../rendering/scene_issue.dart';
import '../rendering/frame_output.dart';
import 'buffer.dart';
import 'texture.dart';
import 'texture_image.dart';
import '../plugins/registration.dart';
part '../rendering/shader.dart';
part '../rendering/shader_compiler.dart';
part '../rendering/shader_bindings.dart';
part '../rendering/pass_descriptor.dart';
part '../rendering/render_graph.dart';
part '../rendering/history_swap.dart';
part '../rendering/graph_compiler.dart';
part '../rendering/graph_validation.dart';
part '../rendering/mesh_shader.dart';

/// Adapter contract for a single device generation. Keys remain backend-private.
/// A successful allocation owns one reference. Release waits for GPU retirement.
abstract interface class ResourceDevice {
  Future<Object> createBuffer(BufferDescriptor descriptor);
  Future<Object> createTexture(TextureDescriptor descriptor);
  Future<void> retain(Object key);
  Future<void> release(Object key);
  Future<void> writeBuffer(Object key, int offset, Uint8List bytes);
  Future<void> writeTexture(Object key, int mipLevel, Uint8List bytes);
  Future<void> generateMipmaps(Object key, MipmapAlphaFilter alphaFilter);
  Future<Uint8List> readBuffer(Object key, int offset, int length);
  Future<Uint8List> readTexture(Object key, int mipLevel);
}

enum ResourceErrorCode {
  invalidCommand,
  staleKey,
  budgetExceeded,
  invalidUsage,
  invalidRange,
  deviceFailed,
}

final class ResourceException implements Exception {
  final ResourceErrorCode code;
  final String message;
  const ResourceException(this.code, this.message);
  @override
  String toString() => 'ResourceException(${code.name}): $message';
}

/// One scope's reference to an allocation. Retain it in another scope before
/// closing its owner; descriptors remain available after GPU ownership ends.
final class GpuResource<T> {
  final ResourceScope _scope;
  final Object _key;
  final ResourceDescriptor<T> descriptor;
  GpuResource._(this._scope, this._key, this.descriptor);
  String get label => descriptor.label;
  bool get isClosed => _scope.isClosed;
}

/// Owns GPU allocations and drains accepted operations before releasing them.
/// Use a backend's createResourceScope to obtain a scope on its native device.
final class ResourceScope {
  final ResourceDevice _device;
  final String label;
  final _owned = <GpuResource<Object?>>[];
  final _children = <ResourceScope>{};
  final _pending = <Future<void>>{};
  final _closedSignal = Completer<void>();
  bool _closed = false;
  Future<void>? _closing;
  ResourceScope(this._device, {this.label = ''});
  bool get isClosed => _closed;

  /// Completes when cleanup settles, even if close reports a release failure.
  Future<void> get whenClosed => _closedSignal.future;

  /// Creates an independently closable owner on the same device. Closing this
  /// scope closes every descendant and drains accepted work throughout the tree.
  ResourceScope createChild({String label = ''}) {
    _checkOpen();
    final child = ResourceScope(_device, label: label);
    _children.add(child);
    child.whenClosed.then((_) => _children.remove(child));
    return child;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Resource scope has closed: $label');
  }

  void _checkResource<T>(GpuResource<T> resource) {
    _checkOpen();
    if (resource.isClosed) {
      throw StateError('Resource owner has closed: ${resource.label}');
    }
    if (!identical(resource._scope, this)) {
      throw ArgumentError('Retain this resource in the receiving scope first.');
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    try {
      _checkOpen();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    final completion = Completer<T>();
    final result = completion.future;
    late Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          _pending.remove(settled);
        });
    _pending.add(settled);
    // Register first, while still invoking uploads synchronously to capture data.
    Future.sync(
      operation,
    ).then(completion.complete, onError: completion.completeError);
    return result;
  }

  Future<GpuResource<T>> _allocate<T>(
    ResourceDescriptor<T> descriptor,
    Future<Object> Function() allocate,
  ) => _run(() async {
    final key = await allocate();
    final resource = GpuResource<T>._(this, key, descriptor);
    _owned.add(resource);
    _checkOpen();
    return resource;
  });
  Future<GpuResource<Buffer>> createBuffer(BufferDescriptor descriptor) =>
      _allocate(descriptor, () => _device.createBuffer(descriptor));
  Future<GpuResource<Texture>> createTexture(TextureDescriptor descriptor) =>
      _allocate(descriptor, () => _device.createTexture(descriptor));
  Future<GpuResource<T>> retain<T>(GpuResource<T> resource) =>
      _allocate(resource.descriptor, () async {
        if (resource.isClosed) throw StateError('Resource owner has closed.');
        if (!identical(resource._scope._device, _device)) {
          throw ArgumentError('Resources cannot cross native devices.');
        }
        await _device.retain(resource._key);
        return resource._key;
      });

  void _bufferRange(
    GpuResource<Buffer> resource,
    int offset,
    int length,
    BufferUsage usage,
  ) {
    _checkResource(resource);
    final descriptor = resource.descriptor as BufferDescriptor;
    if (!descriptor.usage.contains(usage)) {
      throw ArgumentError('Buffer requires ${usage.name} usage.');
    }
    if (offset < 0 ||
        length < 0 ||
        offset > descriptor.size ||
        length > descriptor.size - offset) {
      throw RangeError('Buffer range exceeds ${descriptor.size} bytes.');
    }
    if (offset % 4 != 0 || length == 0 || length % 4 != 0) {
      throw ArgumentError(
        'Buffer transfers need a positive length and four-byte alignment.',
      );
    }
  }

  Uint8List _copy(TypedData data) => Uint8List.fromList(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
  Future<void> writeBuffer(
    GpuResource<Buffer> resource,
    TypedData data, {
    int offset = 0,
  }) => _run(() {
    _bufferRange(
      resource,
      offset,
      data.lengthInBytes,
      BufferUsage.copyDestination,
    );
    return _device.writeBuffer(resource._key, offset, _copy(data));
  });
  Future<Uint8List> readBuffer(
    GpuResource<Buffer> resource, {
    int offset = 0,
    int? length,
  }) => _run(() {
    final count = length ?? resource.descriptor.byteLength - offset;
    _bufferRange(resource, offset, count, BufferUsage.copySource);
    return _device.readBuffer(resource._key, offset, count);
  });
  TextureDescriptor _texture(
    GpuResource<Texture> resource,
    int mipLevel,
    TextureUsage usage,
  ) {
    _checkResource(resource);
    final descriptor = resource.descriptor as TextureDescriptor;
    if (!descriptor.usage.contains(usage)) {
      throw ArgumentError('Texture requires ${usage.name} usage.');
    }
    descriptor.mipByteLength(mipLevel);
    return descriptor;
  }

  Future<void> writeTexture(
    GpuResource<Texture> resource,
    TypedData pixels, {
    int mipLevel = 0,
  }) => _run(() {
    final descriptor = _texture(
      resource,
      mipLevel,
      TextureUsage.copyDestination,
    );
    if (pixels.lengthInBytes != descriptor.mipByteLength(mipLevel)) {
      throw ArgumentError(
        'Upload must contain one complete, tightly packed mip level.',
      );
    }
    return _device.writeTexture(resource._key, mipLevel, _copy(pixels));
  });
  Future<Uint8List> readTexture(
    GpuResource<Texture> resource, {
    int mipLevel = 0,
  }) => _run(() {
    _texture(resource, mipLevel, TextureUsage.copySource);
    return _device.readTexture(resource._key, mipLevel);
  });

  /// Regenerates allocated levels from level zero on the native GPU.
  /// The texture needs sampled and renderAttachment usage. sRGB formats filter
  /// in linear light; the output keeps straight alpha.
  Future<void> generateMipmaps(
    GpuResource<Texture> resource, {
    MipmapAlphaFilter alphaFilter = MipmapAlphaFilter.independent,
  }) => _run(() {
    _texture(resource, 0, TextureUsage.sampled);
    _texture(resource, 0, TextureUsage.renderAttachment);
    return _device.generateMipmaps(resource._key, alphaFilter);
  });

  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      final failures = <Object>[];
      final children = [
        for (final child in _children.toList())
          child.close().then<void>(
            (_) {},
            onError: (Object error, StackTrace _) {
              failures.add(error);
            },
          ),
      ];
      await Future.wait([...children, ..._pending]);
      for (final resource in _owned.reversed) {
        try {
          await _device.release(resource._key);
        } catch (error) {
          failures.add(error);
        }
      }
      _owned.clear();
      if (failures.isNotEmpty) throw ScopeCleanupException(failures);
    } finally {
      _closedSignal.complete();
    }
  }
}
