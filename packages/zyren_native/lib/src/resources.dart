part of 'native_renderer.dart';

/// Payload bytes allocated by explicit resource scopes on this device.
/// Frame targets, legacy scene geometry and temporary readback staging are separate.
final class ResourceStats {
  final int residentBytes, uploadedBytes, liveAllocations;
  const ResourceStats({
    required this.residentBytes,
    required this.uploadedBytes,
    required this.liveAllocations,
  });
}

final class _ResourceKey {
  final Uint8List bytes;
  final TextureDescriptor? texture;
  _ResourceKey(this.bytes, {this.texture});
}

final class _ResourcePacket {
  final _bytes = BytesBuilder(copy: false);
  void u32(int value) {
    _bytes.add(
      (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
    );
  }

  void u64(int value) {
    _bytes.add(
      (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
    );
  }

  void label(String value) {
    final bytes = utf8.encode(value);
    u32(bytes.length);
    _bytes.add(bytes);
  }

  void key(Object key) {
    _bytes.add((key as _ResourceKey).bytes);
  }

  void data(Uint8List value) {
    u64(value.length);
    _bytes.add(value);
  }

  Uint8List finish() => _bytes.takeBytes();
}

final class _NativeResourceDevice
    with _NativeShaders, _NativeGraphs
    implements MaterialDevice, EnvironmentDevice {
  @override
  Uint8List encodeResourceKey(Object key) =>
      Uint8List.fromList((key as _ResourceKey).bytes);
  final NativeGpuTransport _transport;
  @override
  Future<NativeGpuReply> _requestNative(
    String operation,
    Uint8List bytes,
    int capacity,
  ) {
    final control = operation != 'resource';
    if (control
        ? (bytes.length > 8 * 1024 * 1024 || capacity != 256 * 1024)
        : (bytes.length > 64 * 1024 * 1024 + 2048 ||
              capacity < 24 ||
              capacity > 64 * 1024 * 1024 + 24)) {
      return Future.error(
        ArgumentError('Native command transfer exceeds the limit.'),
      );
    }
    return _transport(operation, bytes, capacity);
  }

  int _nextRequest = 0;
  _NativeResourceDevice(this._transport);
  Future<Uint8List> _command(
    int opcode,
    _ResourcePacket body, {
    int responseBytes = 0,
  }) async {
    final payload = body.finish();
    final requestId = ++_nextRequest;
    final packet = _ResourcePacket()
      ..u32(2)
      ..u32(opcode)
      ..u64(requestId)
      ..u64(payload.length);
    packet._bytes.add(payload);
    final result = await _requestNative(
      'resource',
      packet.finish(),
      responseBytes + 24,
    );
    final code = result.status;
    if (code != 0) {
      throw ResourceException(
        code <= ResourceErrorCode.values.length
            ? ResourceErrorCode.values[code - 1]
            : ResourceErrorCode.invalidCommand,
        result.error,
      );
    }
    final response = result.bytes;
    if (response.length != responseBytes + 24) {
      throw StateError('Invalid native resource response length.');
    }
    final header = ByteData.sublistView(response);
    if (header.getUint32(0, Endian.little) != 2 ||
        header.getUint32(4, Endian.little) != 0 ||
        header.getUint64(8, Endian.little) != requestId ||
        header.getUint64(16, Endian.little) != responseBytes) {
      throw StateError('Invalid native resource response header.');
    }
    return Uint8List.sublistView(response, 24);
  }

  @override
  Future<Object> createBuffer(BufferDescriptor d) async => _ResourceKey(
    await _command(
      1,
      _ResourcePacket()
        ..u64(d.size)
        ..u32(d.usage.fold(0, (mask, use) => mask | (1 << use.index)))
        ..label(d.label),
      responseBytes: 32,
    ),
  );
  @override
  Future<Object> createTexture(TextureDescriptor d) async => _ResourceKey(
    await _command(
      11,
      _ResourcePacket()
        ..u32(d.width)
        ..u32(d.height)
        ..u32(d.mipLevels)
        ..u32(d.format.index)
        ..u32(d.usage.fold(0, (mask, use) => mask | (1 << use.index)))
        ..u32(d.depth)
        ..u32(d.dimension.index)
        ..label(d.label),
      responseBytes: 32,
    ),
    texture: d,
  );
  @override
  Future<void> retain(Object key) async {
    await _command(5, _ResourcePacket()..key(key));
  }

  @override
  Future<void> release(Object key) async {
    await _command(6, _ResourcePacket()..key(key));
  }

  @override
  Future<void> writeBuffer(Object key, int offset, Uint8List bytes) async {
    await _command(
      2,
      _ResourcePacket()
        ..key(key)
        ..u64(offset)
        ..data(bytes),
    );
  }

  @override
  Future<void> writeTexture(Object key, int mipLevel, Uint8List bytes) async {
    await _command(
      4,
      _ResourcePacket()
        ..key(key)
        ..u32(mipLevel)
        ..data(bytes),
    );
  }

  @override
  Future<void> generateMipmaps(
    Object key,
    MipmapAlphaFilter alphaFilter,
  ) async {
    await _command(
      10,
      _ResourcePacket()
        ..key(key)
        ..u32(alphaFilter.index),
    );
  }

  @override
  Future<Uint8List> readBuffer(Object key, int offset, int length) => _command(
    7,
    _ResourcePacket()
      ..key(key)
      ..u64(offset)
      ..u64(length),
    responseBytes: length,
  );
  @override
  Future<Uint8List> readTexture(Object key, int mipLevel) => _command(
    9,
    _ResourcePacket()
      ..key(key)
      ..u32(mipLevel),
    responseBytes: (key as _ResourceKey).texture!.mipByteLength(mipLevel),
  );
  Future<ResourceStats> stats() async {
    final data = ByteData.sublistView(
      await _command(8, _ResourcePacket(), responseBytes: 24),
    );
    return ResourceStats(
      residentBytes: data.getUint64(0, Endian.little),
      uploadedBytes: data.getUint64(8, Endian.little),
      liveAllocations: data.getUint64(16, Endian.little),
    );
  }
}
