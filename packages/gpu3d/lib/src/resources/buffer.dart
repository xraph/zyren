import 'dart:convert';

/// Type marker for a native GPU buffer. Instances are owned by ResourceScope.
final class Buffer {
  Buffer._();
}

enum BufferUsage {
  vertex,
  indexBuffer,
  uniform,
  storage,
  copySource,
  copyDestination,
}

abstract class ResourceDescriptor<T> {
  final String label;
  ResourceDescriptor({required this.label}) {
    if (utf8.encode(label).length > 1024) {
      throw ArgumentError.value(
        label,
        'label',
        'Maximum UTF-8 length is 1024 bytes.',
      );
    }
  }
  int get byteLength;
}

/// CPU description. Constructing it does not allocate GPU memory.
final class BufferDescriptor extends ResourceDescriptor<Buffer> {
  final int size;
  final Set<BufferUsage> usage;
  BufferDescriptor({
    super.label = '',
    required this.size,
    required Set<BufferUsage> usage,
  }) : usage = Set.unmodifiable(usage) {
    if (size <= 0 || size > 64 * 1024 * 1024 || size % 4 != 0) {
      throw ArgumentError.value(
        size,
        'size',
        'Use a positive multiple of four, up to 64 MiB.',
      );
    }
    if (usage.isEmpty) throw ArgumentError('Buffer usage must not be empty.');
  }
  @override
  int get byteLength => size;
}
