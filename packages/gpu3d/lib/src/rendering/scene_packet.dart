part of 'frame_submission.dart';

/// Immutable transfer plus the proposed view baseline. Accept only after the
/// native renderer reports that it applied the frame, including hidden frames.
final class EncodedScenePacket {
  final Uint8List bytes;
  final int uploadedBytes, changedMeshes;
  final ScenePacketEncoder _owner;
  final int _revision;
  final SceneSnapshot _scene;
  final Set<int> _uploaded;
  final Set<int> _uploadedTextures;
  EncodedScenePacket._(
    this.bytes,
    this.uploadedBytes,
    this.changedMeshes,
    this._owner,
    this._revision,
    this._scene,
    this._uploaded,
    this._uploadedTextures,
  );
}

/// One serial view's binary encoder. Resources survive visibility changes.
/// Independent views need independent encoders, even when sharing a device.
final class ScenePacketEncoder {
  final int viewId;
  int _next = 0, _accepted = 0;
  SceneSnapshot? _previous;
  Set<int> _uploaded = {};
  Set<int> _uploadedTextures = {};
  ScenePacketEncoder({required this.viewId}) {
    if (viewId <= 0) throw ArgumentError.value(viewId, 'viewId');
  }
  EncodedScenePacket encode(FrameSubmission submission) {
    final scene = submission.scene;
    final previous = _previous;
    final topology =
        previous == null ||
        previous._meshes.length != scene._meshes.length ||
        List.generate(scene._meshes.length, (i) => i).any(
          (i) =>
              previous._meshes[i]['geometry'] != scene._meshes[i]['geometry'],
        );
    final uploaded = _uploaded.intersection(scene._geometries.keys.toSet());
    final visible = {for (final mesh in scene._meshes) mesh['geometry'] as int};
    final uploads = [
      for (final id in visible)
        if (!uploaded.contains(id)) scene._geometries[id]!,
    ];
    final uploadedTextures = _uploadedTextures.intersection(
      scene._textures.keys.toSet(),
    );
    final visibleTextures = {
      for (final mesh in scene._meshes)
        if ((mesh['colorMap'] as List).isNotEmpty)
          (mesh['colorMap'] as List).first as int,
    };
    final textures = [
      for (final id in visibleTextures)
        if (!uploadedTextures.contains(id)) scene._textures[id]!,
    ];
    final updates = <int>[];
    // Choose full replacement before accessing the nullable baseline. Keep this
    // guard explicit for AOT compilation as well as first-frame ownership.
    if (previous == null || topology) {
      updates.addAll(List.generate(scene._meshes.length, (i) => i));
    } else {
      for (var i = 0; i < scene._meshes.length; i++) {
        if (!_sameMesh(scene._meshes[i], previous._meshes[i])) {
          updates.add(i);
        }
      }
    }
    if (scene._geometries.length > 4096 ||
        scene._meshes.length > 4096 ||
        scene._textures.length > 4096) {
      throw ArgumentError(
        'A scene view supports at most 4096 meshes, geometries and images each.',
      );
    }
    var uploadBytes = 0, vertices = 0, indices = 0;
    for (final geometry in uploads) {
      vertices += geometry.positions.length ~/ 3;
      indices += geometry.indices.length;
      uploadBytes +=
          geometry.positions.length * 8 + geometry.indices.length * 4;
      if (geometry.uv0 != null || geometry.uv1 != null) {
        uploadBytes += geometry.positions.length ~/ 3 * 16;
      }
    }
    for (final texture in textures) {
      uploadBytes += texture.descriptor.byteLength;
    }
    if (vertices > 1000000 ||
        indices > 3000000 ||
        uploadBytes > 64 * 1024 * 1024) {
      throw ArgumentError('Scene resource upload exceeds the frame budget.');
    }
    final body = _SceneWriter();
    body.u64(viewId);
    body.u64(topology ? 0 : _accepted);
    body.u32(scene._geometries.length);
    body.u32(uploads.length);
    body.u32(scene._meshes.length);
    body.u32(updates.length);
    body.floats(submission.camera.viewProjection);
    body.floats(scene._background);
    body.floats(scene._light);
    body.floats([scene._ambient]);
    body.u32(scene._textures.length);
    body.u32(textures.length);
    for (final id in scene._geometries.keys) {
      body.u32(id);
    }
    for (final id in scene._textures.keys) {
      body.u32(id);
    }
    for (final image in textures) {
      body.u32(image.id);
      body.u32(image.descriptor.width);
      body.u32(image.descriptor.height);
      body.u32(image.descriptor.format.index);
      body.u32(image.levels.length);
      for (final level in image.levels) {
        body.u32(level.length);
        body.add(level);
      }
      uploadedTextures.add(image.id);
    }
    for (final geometry in uploads) {
      body.u32(geometry.id);
      body.u32(geometry.positions.length ~/ 3);
      body.u32(geometry.indices.length);
      body.u32((geometry.uv0 == null ? 0 : 1) | (geometry.uv1 == null ? 0 : 2));
      body.floats(geometry.positions);
      body.floats(geometry.normals);
      body.integers(geometry.indices);
      if (geometry.uv0 != null) body.floats(geometry.uv0!);
      if (geometry.uv1 != null) body.floats(geometry.uv1!);
      uploaded.add(geometry.id);
    }
    for (final i in updates) {
      final mesh = scene._meshes[i];
      body.u32(i);
      body.u32(mesh['geometry'] as int);
      body.floats((mesh['model'] as List).cast<double>());
      body.floats((mesh['color'] as List).cast<double>());
      body.u32(mesh['unlit'] == true ? 1 : 0);
      final map = (mesh['colorMap'] as List).cast<int>();
      body.u32(map.isEmpty ? 0 : 1);
      body.integers(map);
    }
    final payload = body.finish();
    final revision = ++_next;
    final header = _SceneWriter()
      ..u32(2)
      ..u32(11)
      ..u64(revision)
      ..u64(payload.length);
    header.add(payload);
    return EncodedScenePacket._(
      header.finish().asUnmodifiableView(),
      uploadBytes,
      updates.length,
      this,
      revision,
      scene,
      uploaded,
      uploadedTextures,
    );
  }

  void accept(EncodedScenePacket packet) {
    if (!identical(packet._owner, this) ||
        packet._revision != _next ||
        packet._revision <= _accepted) {
      throw StateError('Only the latest pending packet can advance this view.');
    }
    _previous = packet._scene;
    _uploaded = packet._uploaded;
    _uploadedTextures = packet._uploadedTextures;
    _accepted = packet._revision;
  }
}

bool _sameMesh(Map<String, Object> a, Map<String, Object> b) {
  if (a['geometry'] != b['geometry'] || a['unlit'] != b['unlit']) return false;
  for (final field in ['model', 'color', 'colorMap']) {
    final left = a[field] as List, right = b[field] as List;
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
  }
  return true;
}

final class _SceneWriter {
  final _bytes = BytesBuilder(copy: false);
  void add(Uint8List bytes) => _bytes.add(bytes);
  void u32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError('Scene identifier exceeds uint32.');
    }
    add((ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List());
  }

  void u64(int value) => add(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void integers(List<int> values) {
    final buffer = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      buffer.setUint32(i * 4, values[i], Endian.little);
    }
    add(buffer.buffer.asUint8List());
  }

  void floats(List<double> values) {
    final buffer = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      buffer.setFloat32(i * 4, values[i], Endian.little);
      if (!buffer.getFloat32(i * 4, Endian.little).isFinite) {
        throw ArgumentError('Scene values must fit finite float32 storage.');
      }
    }
    add(buffer.buffer.asUint8List());
  }

  Uint8List finish() => _bytes.takeBytes();
}
