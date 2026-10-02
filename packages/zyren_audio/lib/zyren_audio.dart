import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:zyren/zyren.dart';
import 'src/bindings.dart' as native;

/// Native errors retain the miniaudio result code for host diagnostics.
final class AudioException implements Exception {
  final String operation;
  final int code;
  const AudioException(this.operation, this.code);
  @override
  String toString() => 'AudioException($operation, miniaudio result $code)';
}

void _check(String operation, int code) {
  if (code != 0) throw AudioException(operation, code);
}

void _finite(double value, String name, {double min = 0, double max = 1e12}) {
  if (!value.isFinite || value < min || value > max) {
    throw ArgumentError.value(value, name);
  }
}

enum DistanceAttenuation { none, inverse, linear, exponential }

final class EmitterSettings {
  final double volume, minDistance, maxDistance, rolloff;
  final DistanceAttenuation attenuation;
  final bool loop;
  EmitterSettings({
    this.volume = 1,
    this.minDistance = 1,
    this.maxDistance = 100,
    this.rolloff = 1,
    this.attenuation = DistanceAttenuation.inverse,
    this.loop = false,
  }) {
    _finite(volume, 'volume', max: 1);
    _finite(minDistance, 'minDistance', min: 1e-6);
    _finite(maxDistance, 'maxDistance', min: minDistance + 1e-6);
    _finite(rolloff, 'rolloff', max: 100);
  }
}

/// Attaches to a scene node. Generic nodes face local +Z, matching Object3D.lookAt.
/// Cameras use their public target/up pose, matching Zyren's camera projection.
final class AudioListener {
  final Object3D node;
  final Vec3 localForward, localUp;
  AudioListener(
    this.node, {
    this.localForward = const Vec3(0, 0, 1),
    this.localUp = const Vec3(0, 1, 0),
  }) {
    _axes(localForward, localUp);
  }
  ({Vec3 position, Vec3 forward, Vec3 up}) get pose {
    if (node case final Camera camera) {
      final axes = _axes(camera.target - camera.position, camera.up);
      return (position: camera.position, forward: axes.$1, up: axes.$2);
    }
    final m = node.worldMatrix.storage;
    Vec3 direction(Vec3 v) => Vec3(
      m[0] * v.x + m[4] * v.y + m[8] * v.z,
      m[1] * v.x + m[5] * v.y + m[9] * v.z,
      m[2] * v.x + m[6] * v.y + m[10] * v.z,
    );
    final axes = _axes(direction(localForward), direction(localUp));
    return (position: Vec3(m[12], m[13], m[14]), forward: axes.$1, up: axes.$2);
  }
}

(Vec3, Vec3) _axes(Vec3 forward, Vec3 up) {
  final f = forward.normalized();
  final right = f.cross(up).normalized();
  return (f, right.cross(f).normalized());
}

Vec3 _position(Object3D node) {
  final m = node.worldMatrix.storage;
  return Vec3(m[12], m[13], m[14]);
}

void _coordinate(Vec3 v) {
  for (final value in v.storage) {
    _finite(value, 'audio coordinate', min: -1e12);
  }
}

final class AudioEmitter {
  final String id;
  final Object3D node;
  final SpatialAudio _owner;
  final Pointer<Void> _voice;
  final int _bytes;
  EmitterSettings _settings;
  bool _closed = false;
  AudioEmitter._(
    this.id,
    this.node,
    this._owner,
    this._voice,
    this._bytes,
    this._settings,
  );
  bool get isClosed => _closed;
  bool get isPlaying => !_closed && native.playing(_voice) != 0;
  EmitterSettings get settings => _settings;
  void configure(EmitterSettings value) {
    _checkOpen();
    native.settings(
      _voice,
      value.volume,
      value.minDistance,
      value.maxDistance,
      value.rolloff,
      value.attenuation.index,
      value.loop ? 1 : 0,
    );
    _settings = value;
    _owner._revision++;
  }

  void play({bool restart = false}) {
    _checkOpen();
    _owner.sync();
    _checkOpen();
    if (restart) _check('rewind', native.rewind(_voice));
    _check('play', native.play(_voice));
    _owner._revision++;
  }

  void pause() {
    _checkOpen();
    _check('pause', native.pause(_voice));
    _owner._revision++;
  }

  void close() {
    if (_closed) return;
    native.freeVoice(_owner._engine, _voice);
    _closed = true;
    _owner._emitters.remove(id);
    _owner._residentBytes -= _bytes;
    _owner._revision++;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Emitter has closed: $id');
    _owner._checkOpen();
  }
}

/// One native engine, one listener and bounded mono PCM emitters.
/// Call sync after scene edits and close when your attachment is disposed.
final class SpatialAudio implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf(native.freeEngine),
  );
  final Object3D root;
  final AudioListener listener;
  final bool offline;
  final int sampleRate, maxEmitters, maxPcmBytes;
  final Pointer<Void> _engine;
  final String backend;
  final _emitters = <String, AudioEmitter>{};
  int _residentBytes = 0, _revision = 0;
  bool _closed = false;

  SpatialAudio._(
    this.root,
    this.listener,
    this.offline,
    this.sampleRate,
    this.maxEmitters,
    this.maxPcmBytes,
    this._engine,
    this.backend,
  ) {
    _finalizer.attach(this, _engine, detach: this);
  }

  factory SpatialAudio({
    required Object3D root,
    required AudioListener listener,
    bool offline = false,
    int sampleRate = 48000,
    int maxEmitters = 64,
    int maxPcmBytes = 64 * 1024 * 1024,
  }) {
    if (sampleRate < 8000 ||
        sampleRate > 192000 ||
        maxEmitters < 1 ||
        maxEmitters > 1024 ||
        maxPcmBytes < 4 ||
        maxPcmBytes > 512 * 1024 * 1024) {
      throw ArgumentError('Invalid audio limits.');
    }
    if (!_attached(root, listener.node)) {
      throw ArgumentError('Listener must belong to the scene root.');
    }
    final pose = listener.pose;
    _coordinate(pose.position);
    final output = calloc<Pointer<Void>>();
    try {
      _check(
        'initialize native output',
        native.create(offline ? 1 : 0, sampleRate, output),
      );
      final audio = SpatialAudio._(
        root,
        listener,
        offline,
        sampleRate,
        maxEmitters,
        maxPcmBytes,
        output.value,
        native.backendName(output.value).cast<Utf8>().toDartString(),
      );
      try {
        audio.sync();
      } catch (_) {
        audio.close();
        rethrow;
      }
      return audio;
    } finally {
      calloc.free(output);
    }
  }
  int get revision => _revision;
  int get residentPcmBytes => _residentBytes;
  bool get isClosed => _closed;
  List<AudioEmitter> get emitters => List.unmodifiable(_emitters.values);

  /// Samples are mono float32 [-1,1] at this engine's sample rate, copied natively.
  AudioEmitter add({
    required String id,
    required Object3D node,
    required Float32List samples,
    EmitterSettings? settings,
  }) {
    _checkOpen();
    if (id.trim().isEmpty || _emitters.containsKey(id)) {
      throw ArgumentError('Emitter ID must be unique and nonblank.');
    }
    if (!_attached(root, node)) {
      throw ArgumentError('Emitter must belong to the scene root.');
    }
    _coordinate(_position(node));
    if (samples.isEmpty ||
        samples.lengthInBytes > maxPcmBytes - _residentBytes ||
        _emitters.length >= maxEmitters ||
        samples.any((v) => !v.isFinite || v.abs() > 1)) {
      throw ArgumentError('Invalid PCM or audio budget exceeded.');
    }
    final config = settings ?? EmitterSettings();
    final data = calloc<Float>(samples.length),
        output = calloc<Pointer<Void>>();
    try {
      data.asTypedList(samples.length).setAll(0, samples);
      _check(
        'create emitter',
        native.createVoice(_engine, data, samples.length, output),
      );
      final emitter = AudioEmitter._(
        id,
        node,
        this,
        output.value,
        samples.lengthInBytes,
        config,
      );
      _emitters[id] = emitter;
      _residentBytes += samples.lengthInBytes;
      emitter.configure(config);
      final p = _position(node);
      native.position(emitter._voice, p.x, p.y, p.z);
      return emitter;
    } finally {
      calloc.free(data);
      calloc.free(output);
    }
  }

  /// Removes detached emitters. A detached listener pauses playback and fails.
  void sync() {
    _checkOpen();
    for (final emitter in _emitters.values.toList()) {
      if (!_attached(root, emitter.node)) emitter.close();
    }
    if (!_attached(root, listener.node)) {
      for (final emitter in _emitters.values) {
        emitter.pause();
      }
      throw StateError('Listener was detached from the scene.');
    }
    final pose = listener.pose;
    _coordinate(pose.position);
    final positions = {
      for (final emitter in _emitters.values) emitter: _position(emitter.node),
    };
    positions.values.forEach(_coordinate);
    native.listener(
      _engine,
      pose.position.x,
      pose.position.y,
      pose.position.z,
      pose.forward.x,
      pose.forward.y,
      pose.forward.z,
      pose.up.x,
      pose.up.y,
      pose.up.z,
    );
    for (final entry in positions.entries) {
      native.position(
        entry.key._voice,
        entry.value.x,
        entry.value.y,
        entry.value.z,
      );
    }
  }

  /// Reads the real native mixer without a device. Playback mode rejects reads.
  Float32List renderOffline(int frames) {
    _checkOpen();
    if (!offline) {
      throw StateError('Offline reads require explicit offline mode.');
    }
    if (frames < 1 || frames > sampleRate * 10) {
      throw ArgumentError.value(frames, 'frames');
    }
    sync();
    final output = calloc<Float>(frames * 2);
    try {
      _check('render offline', native.read(_engine, output, frames));
      return Float32List.fromList(output.asTypedList(frames * 2));
    } finally {
      calloc.free(output);
    }
  }

  void close() {
    if (_closed) return;
    for (final emitter in _emitters.values.toList()) {
      emitter.close();
    }
    _closed = true;
    _finalizer.detach(this);
    native.freeEngine(_engine);
    _revision++;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Audio engine has closed.');
  }

  static bool _attached(Object3D root, Object3D node) {
    for (Object3D? current = node; current != null; current = current.parent) {
      if (identical(current, root)) return true;
    }
    return false;
  }
}
