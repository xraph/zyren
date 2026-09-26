import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'bindings.dart' as native;
import 'scene.dart';

class RenderedFrame {
  final Uint8List pixels;
  final int width, height;
  const RenderedFrame(this.pixels, this.width, this.height);
}

/// One native GPU device, owned by a persistent worker isolate.
/// Await [dispose] when you no longer need it.
class NativeRenderer {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _exits;
  final Map<int, Completer<Object?>> _pending = {};
  final ReceivePort _responses;
  Set<int> _uploaded = {};
  int _nextRequest = 1;
  Future<RenderedFrame>? _frame;
  Future<void>? _disposal;
  bool _closed = false;
  bool _dead = false;

  NativeRenderer._(
    this._isolate,
    this._commands,
    this._exits,
    this._responses,
  ) {
    _responses.listen((dynamic message) {
      final data = message as List;
      final completion = _pending.remove(data[0]);
      if (data[1] == true) {
        completion?.complete(data[2]);
      } else {
        completion?.completeError(StateError(data[2] as String));
      }
    });
    _exits.listen((dynamic message) {
      _dead = true;
      for (final completion in _pending.values) {
        completion.completeError(
          StateError('Native renderer worker exited: $message'),
        );
      }
      _pending.clear();
    });
  }

  static Future<NativeRenderer> create() async {
    final ready = ReceivePort(),
        exits = ReceivePort(),
        responses = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _renderWorker,
        ready.sendPort,
        onError: ready.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
      );
      final result = await ready.first;
      if (result is! SendPort) {
        throw StateError('Native renderer initialization failed: $result');
      }
      return NativeRenderer._(isolate, result, exits, responses);
    } catch (_) {
      isolate?.kill();
      exits.close();
      responses.close();
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<Object?> _request(String operation, List<Object> arguments) {
    if (_dead) {
      return Future.error(StateError('Native renderer worker is unavailable.'));
    }
    final id = _nextRequest++;
    final completion = Completer<Object?>();
    _pending[id] = completion;
    _commands.send([id, _responses.sendPort, operation, ...arguments]);
    return completion.future;
  }

  Future<RenderedFrame> render(
    Scene scene,
    PerspectiveCamera camera, {
    required int width,
    required int height,
  }) {
    if (_closed) return Future.error(StateError('Renderer has been disposed.'));
    if (_frame != null) {
      return Future.error(StateError('Only one frame may be in flight.'));
    }
    if (width < 1 || height < 1 || width > 4096 || height > 4096) {
      return Future.error(
        ArgumentError('Render dimensions must be in [1, 4096].'),
      );
    }
    Future<RenderedFrame> submit() async {
      final frame = scene.snapshot(camera, width / height, uploaded: _uploaded);
      final active = (frame['meshes'] as List<Map<String, Object>>)
          .map((m) => m['geometry'] as int)
          .toSet();
      final bytes =
          await _request('render', [jsonEncode(frame), width, height])
              as TransferableTypedData;
      _uploaded = active;
      return RenderedFrame(bytes.materialize().asUint8List(), width, height);
    }

    final future = submit();
    _frame = future;
    return future.whenComplete(() {
      _frame = null;
    });
  }

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    try {
      try {
        await _frame;
      } catch (_) {
        /* Cleanup still owns the device. */
      }
      if (!_dead) await _request('dispose', []);
    } finally {
      _isolate.kill();
      _responses.close();
      _exits.close();
    }
  }
}

String _lastError() {
  final length = native.lastError(nullptr, 0);
  if (length == 0) return 'Unknown native renderer error.';
  final buffer = calloc<Uint8>(length);
  try {
    native.lastError(buffer, length);
    return utf8.decode(buffer.asTypedList(length), allowMalformed: true);
  } finally {
    calloc.free(buffer);
  }
}

final class _NativeOwner implements Finalizable {
  static final _finalizer = NativeFinalizer(Native.addressOf(native.finalize));
  final int handle;
  _NativeOwner(this.handle) {
    _finalizer.attach(this, Pointer<Void>.fromAddress(handle), detach: this);
  }
  void close() {
    if (native.destroy(handle) != 1) throw StateError(_lastError());
    _finalizer.detach(this);
  }
}

void _renderWorker(SendPort ready) {
  var handle = 0;
  late final _NativeOwner owner;
  final commands = ReceivePort();
  try {
    if (native.abiVersion() != 1) {
      throw StateError('Unsupported native ABI version.');
    }
    handle = native.create();
    if (handle == 0) throw StateError(_lastError());
    owner = _NativeOwner(handle);
    ready.send(commands.sendPort);
  } catch (error) {
    if (handle != 0) native.destroy(handle);
    ready.send(error.toString());
    commands.close();
    return;
  }
  commands.listen((dynamic message) {
    final data = message as List;
    final id = data[0] as int, reply = data[1] as SendPort;
    try {
      if (data[2] == 'dispose') {
        owner.close();
        reply.send([id, true, null]);
        return;
      }
      final json = utf8.encode(data[3] as String);
      final width = data[4] as int, height = data[5] as int;
      final input = calloc<Uint8>(json.length),
          pixels = calloc<Uint8>(width * height * 4);
      try {
        input.asTypedList(json.length).setAll(0, json);
        if (native.render(
              owner.handle,
              input,
              json.length,
              width,
              height,
              pixels,
              width * height * 4,
            ) !=
            1) {
          throw StateError(_lastError());
        }
        reply.send([
          id,
          true,
          TransferableTypedData.fromList([
            pixels.asTypedList(width * height * 4),
          ]),
        ]);
      } finally {
        calloc.free(input);
        calloc.free(pixels);
      }
    } catch (error) {
      reply.send([id, false, error.toString()]);
    }
  });
}
