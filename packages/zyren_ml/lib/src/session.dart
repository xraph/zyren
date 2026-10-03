import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'manifest.dart';
import 'native_bindings.dart';
import 'result.dart';
import 'tensor.dart';

/// Owns a native session; inputs and outputs never share native storage.
/// Close explicitly. A native finalizer is a backup for abandoned sessions.
final class MlSession implements Finalizable {
  MlSession._(this.manifest, this._handle) {
    sessionFinalizer.attach(this, _handle, detach: this);
  }

  final MlModelManifest manifest;
  Pointer<Void> _handle;
  bool get isClosed => _handle == nullptr;

  Future<MlRunResult> run(
    MlTensorMap inputs, [
    MlRunOptions options = const MlRunOptions(),
  ]) async {
    final watch = Stopwatch()..start();
    MlRunResult result(
      MlRunStatus status, {
      String? message,
      MlTensorMap tensors = const {},
    }) => MlRunResult(
      status,
      message: message,
      tensors: tensors,
      requestId: options.requestId,
      elapsed: watch.elapsed,
    );
    if (isClosed) {
      return result(MlRunStatus.unavailable, message: 'Session is closed.');
    }
    if (options.isCancelled) {
      return result(
        MlRunStatus.cancelled,
        message: 'Request cancelled or deadline expired.',
      );
    }
    if (inputs.length != manifest.inputs.length ||
        manifest.inputs.any(
          (spec) =>
              !inputs.containsKey(spec.name) ||
              !spec.accepts(inputs[spec.name]!),
        )) {
      return result(
        MlRunStatus.invalid,
        message:
            'Missing, unexpected, nonfinite or incompatible input tensors.',
      );
    }
    int? batch;
    for (final spec in manifest.inputs) {
      if (spec.shape.isNotEmpty && spec.shape.first == -1) {
        final n = inputs[spec.name]!.shape.first;
        if (batch != null && batch != n) {
          return result(
            MlRunStatus.invalid,
            message: 'Input batch dimensions differ.',
          );
        }
        batch = n;
      }
    }
    try {
      return using<MlRunResult>((arena) {
        final names = arena<Pointer<Uint8>>(manifest.inputs.length);
        final tensors = arena<NativeTensor>(manifest.inputs.length);
        for (var i = 0; i < manifest.inputs.length; i++) {
          final spec = manifest.inputs[i];
          final tensor = inputs[spec.name]!;
          names[i] = spec.name.toNativeUtf8(allocator: arena).cast();
          final native = tensors[i];
          native.dtype = tensor.dtype.nativeCode;
          native.rank = tensor.shape.length;
          native.dimensions = arena<Int64>(tensor.shape.length);
          for (var j = 0; j < tensor.shape.length; j++) {
            native.dimensions[j] = tensor.shape[j];
          }
          native.byteLength = tensor.byteLength;
          native.data = arena<Uint8>(tensor.byteLength)
            ..asTypedList(tensor.byteLength).setAll(0, tensor.bytes);
        }
        final outputNames = arena<Pointer<Uint8>>(manifest.outputs.length);
        for (var i = 0; i < manifest.outputs.length; i++) {
          outputNames[i] = manifest.outputs[i].name
              .toNativeUtf8(allocator: arena)
              .cast();
        }
        final nativeResult = arena<Pointer<Void>>();
        final error = arena<Uint8>(4096);
        if (options.isCancelled) {
          return result(
            MlRunStatus.cancelled,
            message: 'Request expired during input preparation.',
          );
        }
        final status = nativeRun(
          _handle,
          names,
          tensors,
          manifest.inputs.length,
          outputNames,
          manifest.outputs.length,
          nativeResult,
          error,
          4096,
        );
        try {
          if (status != 0) {
            return result(
              nativeStatus(status),
              message: error.cast<Utf8>().toDartString(),
            );
          }
          if (options.isCancelled) {
            return result(
              MlRunStatus.cancelled,
              message: 'Result exceeded deadline or was cancelled.',
            );
          }
          final outputs = <String, MlTensor>{};
          final output = arena<NativeTensor>();
          for (var i = 0; i < manifest.outputs.length; i++) {
            final readStatus = nativeResultTensor(
              nativeResult.value,
              i,
              output,
              error,
              4096,
            );
            if (readStatus != 0) {
              return result(
                nativeStatus(readStatus),
                message: error.cast<Utf8>().toDartString(),
              );
            }
            final native = output.ref;
            final dtype = MlDtype.values
                .where((t) => t.nativeCode == native.dtype)
                .firstOrNull;
            if (dtype == null) {
              return result(
                MlRunStatus.unsupported,
                message: 'Unsupported output dtype.',
              );
            }
            final shape = List.generate(
              native.rank,
              (j) => native.dimensions[j],
            );
            final tensor = MlTensor(
              dtype,
              shape,
              native.data.asTypedList(native.byteLength),
            );
            final spec = manifest.outputs[i];
            if (!spec.accepts(tensor) ||
                (batch != null &&
                    spec.shape.isNotEmpty &&
                    spec.shape.first == -1 &&
                    tensor.shape.first != batch)) {
              return result(
                MlRunStatus.invalid,
                message:
                    'Output differs from manifest or contains nonfinite values.',
              );
            }
            outputs[spec.name] = tensor;
          }
          return result(MlRunStatus.ok, tensors: outputs);
        } finally {
          if (nativeResult.value != nullptr) {
            nativeResultClose(nativeResult.value);
          }
        }
      });
    } on ArgumentError catch (e) {
      return result(MlRunStatus.invalid, message: e.toString());
    } catch (e) {
      return result(MlRunStatus.failed, message: e.toString());
    }
  }

  Future<void> close() async {
    if (isClosed) return;
    sessionFinalizer.detach(this);
    nativeClose(_handle);
    _handle = nullptr;
  }
}

MlRunStatus nativeStatus(int status) => switch (status) {
  0 => MlRunStatus.ok,
  1 => MlRunStatus.invalid,
  2 => MlRunStatus.unsupported,
  _ => MlRunStatus.failed,
};

MlSession loadValidatedSession(MlModelManifest manifest, List<int> model) {
  return using((arena) {
    final bytes = arena<Uint8>(model.length)
      ..asTypedList(model.length).setAll(0, model);
    final out = arena<Pointer<Void>>();
    final error = arena<Uint8>(4096);
    final status = nativeOpen(
      ortGetApiBase(),
      bytes,
      model.length,
      out,
      error,
      4096,
    );
    if (status != 0) {
      throw MlLoadException(
        nativeStatus(status),
        error.cast<Utf8>().toDartString(),
      );
    }
    return MlSession._(manifest, out.value);
  });
}
