import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'bindings.dart' as native;
import 'surface.dart';
import 'worker_session.dart';

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

void renderWorker(WorkerBootstrap start) {
  if (native.abiVersion() != 1) {
    throw StateError('Unsupported native ABI version.');
  }
  final handle = native.create();
  if (handle == 0) throw StateError(_lastError());
  final owner = _NativeOwner(handle);
  final commands = ReceivePort();
  start.messages.send(WorkerReady(start.generation, commands.sendPort));
  commands.listen((dynamic value) {
    final request = value as WorkerRequest;
    if (request.generation != start.generation) return;
    void reply(bool success, Object? value) => start.messages.send(
      WorkerReply(request.id, start.generation, success, value),
    );
    try {
      if (request.operation == 'dispose') {
        owner.close();
        reply(true, null);
        commands.close();
        return;
      }
      if (request.operation == 'resource') {
        final bytes = (request.arguments[0] as TransferableTypedData)
            .materialize()
            .asUint8List();
        final capacity = request.arguments[1] as int;
        if (bytes.length > 64 * 1024 * 1024 + 2048 ||
            capacity < 24 ||
            capacity > 64 * 1024 * 1024 + 24) {
          throw ArgumentError('Resource transfer exceeds the native limit.');
        }
        final input = calloc<Uint8>(bytes.length),
            output = calloc<Uint8>(capacity);
        final written = calloc<Size>();
        try {
          input.asTypedList(bytes.length).setAll(0, bytes);
          final status = native.resourceCommand(
            owner.handle,
            input,
            bytes.length,
            output,
            capacity,
            written,
          );
          reply(true, <Object>[
            status,
            status == 0
                ? TransferableTypedData.fromList([
                    output.asTypedList(written.value),
                  ])
                : _lastError(),
          ]);
        } finally {
          calloc.free(input);
          calloc.free(output);
          calloc.free(written);
        }
        return;
      }
      if (request.operation == 'surfaceAttach') {
        NativeSurfaces().attachRenderer(
          owner.handle,
          NativeSurfaceKey.fromMessage(request.arguments[0] as List<int>),
        );
        reply(true, null);
        return;
      }
      if (request.operation == 'surfaceRender') {
        try {
          final receipt = NativeSurfaces().renderApple(
            owner.handle,
            NativeSurfaceKey.fromMessage(request.arguments[1] as List<int>),
            request.arguments[2] as int,
            request.arguments[3] as int,
            request.arguments[0] as String,
          );
          reply(true, <int>[0, ...receipt]);
        } on NativeSurfaceException catch (error) {
          reply(true, <int>[error.code]);
        }
        return;
      }
      if (request.operation != 'render') {
        throw ArgumentError('Unknown worker operation.');
      }
      final json = utf8.encode(request.arguments[0] as String);
      final width = request.arguments[1] as int,
          height = request.arguments[2] as int;
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
        reply(
          true,
          TransferableTypedData.fromList([
            pixels.asTypedList(width * height * 4),
          ]),
        );
      } finally {
        calloc.free(input);
        calloc.free(pixels);
      }
    } catch (error) {
      reply(false, error.toString());
      if (request.operation == 'dispose') commands.close();
    }
  });
}
