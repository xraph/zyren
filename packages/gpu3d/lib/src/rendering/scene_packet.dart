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
  EncodedScenePacket._(
    this.bytes,
    this.uploadedBytes,
    this.changedMeshes,
    this._owner,
    this._revision,
    this._scene,
    this._uploaded,
  );
}

/// One serial view's binary encoder. Resources survive visibility changes.
/// Independent views need independent encoders, even when sharing a device.
final class ScenePacketEncoder {
  final int viewId;
  int _next = 0, _accepted = 0;
  SceneSnapshot? _previous;
  Set<int> _uploaded = {};
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
    if (scene._geometries.length > 4096 || scene._meshes.length > 4096) {
      throw ArgumentError(
        'A scene view supports at most 4096 meshes and geometries.',
      );
    }
    var geometryBytes = 0, vertices = 0, indices = 0;
    for (final geometry in uploads) {
      vertices += geometry.positions.length ~/ 3;
      indices += geometry.indices.length;
      geometryBytes +=
          geometry.positions.length * 8 + geometry.indices.length * 4;
    }
    if (vertices > 1000000 ||
        indices > 3000000 ||
        geometryBytes > 64 * 1024 * 1024) {
      throw ArgumentError('Geometry upload exceeds the frame budget.');
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
    for (final id in scene._geometries.keys) {
      body.u32(id);
    }
    for (final geometry in uploads) {
      body.u32(geometry.id);
      body.u32(geometry.positions.length ~/ 3);
      body.u32(geometry.indices.length);
      body.floats(geometry.positions);
      body.floats(geometry.normals);
      body.integers(geometry.indices);
      uploaded.add(geometry.id);
    }
    for (final i in updates) {
      final mesh = scene._meshes[i];
      body.u32(i);
      body.u32(mesh['geometry'] as int);
      body.floats((mesh['model'] as List).cast<double>());
      body.floats((mesh['color'] as List).cast<double>());
      body.u32(mesh['unlit'] == true ? 1 : 0);
    }
    final payload = body.finish();
    final revision = ++_next;
    final header = _SceneWriter()
      ..u32(2)
      ..u32(10)
      ..u64(revision)
      ..u64(payload.length);
    header.add(payload);
    return EncodedScenePacket._(
      header.finish().asUnmodifiableView(),
      geometryBytes,
      updates.length,
      this,
      revision,
      scene,
      uploaded,
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
    _accepted = packet._revision;
  }
}

bool _sameMesh(Map<String, Object> a, Map<String, Object> b) {
  if (a['geometry'] != b['geometry'] || a['unlit'] != b['unlit']) return false;
  for (final field in ['model', 'color']) {
    final left = a[field] as List, right = b[field] as List;
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
