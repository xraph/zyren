part of 'native_renderer.dart';

/// Payload bytes allocated by scene resources and explicit scopes on this device.
/// Frame targets, driver padding and temporary readback staging are separate.
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
    implements MaterialDevice, EnvironmentDevice, MeshShaderDevice {
  @override
  Uint8List encodeResourceKey(Object key) =>
      Uint8List.fromList((key as _ResourceKey).bytes);
  final NativeGpuCommandSender _send;
  Future<T> submitFrame<T>(
    FrameSubmission submission,
    Uint8List packet,
    Future<T> Function(Uint8List bytes) submit, {
    EncodedScenePacket? scenePacket,
  }) {
    if (scenePacket != null && !scenePacket.ready) {
      final prefix = scenePacket.bindingHeader;
      if (prefix == null || prefix.isEmpty) {
        return Future.sync(() => submit(packet));
      }
      final bytes = Uint8List(prefix.length + packet.length)
        ..setAll(0, prefix)
        ..setAll(prefix.length, packet);
      ByteData.sublistView(bytes).setUint64(8, packet.length, Endian.little);
      return Future.sync(() => submit(bytes));
    }
    final send = submit;
    submit = (bytes) {
      scenePacket?.bindingHeader = Uint8List.fromList(
        bytes.sublist(0, bytes.length - packet.length),
      );
      return send(bytes);
    };
    final programs = submission.scene.meshShaders;
    final unique = programs.values.toSet().toList();
    final keys = <MeshShaderProgram, _MeshShaderKey>{};
    Future<T> encode(Object? graph, [List<Object>? environmentKeys]) {
      if (keys.isEmpty && graph == null && environmentKeys == null) {
        return Future.sync(() => submit(packet));
      }
      final graphKey = (graph as _GraphKey?)?.values;
      final environment = submission.environment;
      final version = environmentKeys != null ? 3 : (keys.isEmpty ? 1 : 2);
      final base = version == 3 ? 184 : (version == 2 ? 56 : 48);
      final header = base + (version >= 2 ? programs.length * 40 : 0);
      final envelope = ByteData(header + packet.length)
        ..setUint32(0, 3, Endian.little)
        ..setUint32(4, version, Endian.little)
        ..setUint64(8, packet.length, Endian.little);
      if (version >= 2) {
        envelope.setUint32(16, programs.length, Endian.little);
        envelope.setUint32(20, graphKey == null ? 0 : 1, Endian.little);
        var offset = base;
        for (final entry in programs.entries) {
          envelope.setUint32(offset, entry.key, Endian.little);
          for (var i = 0; i < 4; i++) {
            envelope.setUint64(
              offset + 8 + i * 8,
              keys[entry.value]!.values[i],
              Endian.little,
            );
          }
          offset += 40;
        }
      }
      if (graphKey != null) {
        for (var i = 0; i < 4; i++) {
          envelope.setUint64(
            (version == 1 ? 16 : 24) + i * 8,
            graphKey[i],
            Endian.little,
          );
        }
      }
      if (environmentKeys != null) {
        for (var i = 0; i < 3; i++) {
          envelope.buffer.asUint8List().setRange(
            56 + i * 32,
            88 + i * 32,
            (environmentKeys[i] as _ResourceKey).bytes,
          );
        }
        envelope.setFloat32(152, environment!.intensity, Endian.little);
        final rotation = environment.rotation;
        for (final (i, value) in [
          rotation.x,
          rotation.y,
          rotation.z,
          rotation.w,
        ].indexed) {
          envelope.setFloat32(156 + i * 4, value, Endian.little);
        }
      }
      final bytes = envelope.buffer.asUint8List()
        ..setRange(header, header + packet.length, packet);
      return submit(bytes);
    }

    Future<T> hold(int index) {
      if (index == unique.length) {
        final graph = submission.graph;
        Future<T> withEnvironment(Object? graphKey) {
          final environment = submission.environment;
          return environment == null
              ? encode(graphKey)
              : environment.map.submitFrame(
                  this,
                  (keys) => encode(graphKey, keys),
                );
        }

        return graph == null
            ? withEnvironment(null)
            : graph.submitFrame(this, submission.size, withEnvironment);
      }
      return unique[index].submitFrame(this, (key) {
        keys[unique[index]] = key as _MeshShaderKey;
        return hold(index + 1);
      });
    }

    return hold(0);
  }

  int _nextRequest = 0;
  _NativeResourceDevice(this._send);
  int resourceBudgetBytes = 256 * 1024 * 1024;
  Future<void> configureBudget(int bytes) async {
    RangeError.checkValueInInterval(
      bytes,
      16 * 1024 * 1024,
      1024 * 1024 * 1024,
      'resourceBudgetBytes',
    );
    await _command(13, _ResourcePacket()..u64(bytes));
    resourceBudgetBytes = bytes;
  }

  @override
  Future<NativeGpuReply> _submit(
    NativeGpuCommand kind,
    Uint8List bytes,
    int capacity,
  ) async {
    final control = kind != NativeGpuCommand.resource;
    if (bytes.isEmpty ||
        (control
            ? (bytes.length > 8 * 1024 * 1024 || capacity != 256 * 1024)
            : (bytes.length > 64 * 1024 * 1024 + 2048 ||
                  capacity < 24 ||
                  capacity > 64 * 1024 * 1024 + 24))) {
      throw ArgumentError('Native command transfer exceeds the limit.');
    }
    final reply = await _send(kind, bytes, capacity);
    if (reply.status == 0 && reply.bytes!.length > capacity) {
      throw StateError('Native command exceeded response capacity.');
    }
    return reply;
  }

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
    final result = await _submit(
      NativeGpuCommand.resource,
      packet.finish(),
      responseBytes + 24,
    );
    final code = result.status;
    if (code != 0) {
      throw ResourceException(
        code <= ResourceErrorCode.values.length
            ? ResourceErrorCode.values[code - 1]
            : ResourceErrorCode.invalidCommand,
        result.message!,
      );
    }
    final response = result.bytes!;
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
      12,
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
  Future<Set<TextureFormat>> textureFormats() async {
    final bytes = await _command(11, _ResourcePacket(), responseBytes: 4);
    final mask = ByteData.sublistView(bytes).getUint32(0, Endian.little);
    return Set.unmodifiable({
      for (final format in TextureFormat.values)
        if (mask & (1 << format.index) != 0) format,
    });
  }

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
