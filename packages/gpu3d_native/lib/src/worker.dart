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
      if (request.operation == 'sceneClose') {
        if (native.closeScene(owner.handle, request.arguments[0] as int) != 1) {
          throw StateError(_lastError());
        }
        reply(true, null);
        return;
      }
      if (request.operation == 'resource' ||
          request.operation == 'shader' ||
          request.operation == 'graph') {
        final bytes = (request.arguments[0] as TransferableTypedData)
            .materialize()
            .asUint8List();
        final capacity = request.arguments[1] as int;
        final control = request.operation != 'resource';
        if (control
            ? (bytes.length > 8 * 1024 * 1024 || capacity != 256 * 1024)
            : (bytes.length > 64 * 1024 * 1024 + 2048 ||
                  capacity < 24 ||
                  capacity > 64 * 1024 * 1024 + 24)) {
          throw ArgumentError('Native command transfer exceeds the limit.');
        }
        final input = calloc<Uint8>(bytes.length),
            output = calloc<Uint8>(capacity);
        final written = calloc<Size>();
        try {
          input.asTypedList(bytes.length).setAll(0, bytes);
          final command = switch (request.operation) {
            'shader' => native.shaderCommand,
            'graph' => native.graphCommand,
            _ => native.resourceCommand,
          };
          final status = command(
            owner.handle,
            input,
            bytes.length,
            output,
            capacity,
            written,
          );
          if (written.value > capacity) {
            throw StateError('Native command exceeded response capacity.');
          }
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
          final receipt = NativeSurfaces().renderAppleBytes(
            owner.handle,
            NativeSurfaceKey.fromMessage(request.arguments[1] as List<int>),
            request.arguments[2] as int,
            request.arguments[3] as int,
            (request.arguments[0] as TransferableTypedData)
                .materialize()
                .asUint8List(),
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
      final value = request.arguments[0];
      final json = value is String
          ? utf8.encode(value)
          : (value as TransferableTypedData).materialize().asUint8List();
      final width = request.arguments[1] as int,
          height = request.arguments[2] as int;
      final input = calloc<Uint8>(json.length),
          pixels = calloc<Uint8>(width * height * 4);
      try {
        input.asTypedList(json.length).setAll(0, json);
        final before = native.sceneUploadedBytes(owner.handle);
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
        reply(true, <Object>[
          TransferableTypedData.fromList([
            pixels.asTypedList(width * height * 4),
          ]),
          native.sceneUploadedBytes(owner.handle) - before,
          native.sceneResidentBytes(owner.handle),
        ]);
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
