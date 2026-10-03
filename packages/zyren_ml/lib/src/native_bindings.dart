import 'dart:ffi';

// Only this private library contains native handles. The ORT and shim assets
// are loaded separately, so no rpath or system ONNX installation is needed.
const _shim = 'package:zyren_ml/src/native_bindings.dart';
const _ort = 'package:zyren_ml/onnxruntime';

final class NativeTensor extends Struct {
  @Int32()
  external int dtype;
  @Int32()
  external int rank;
  external Pointer<Int64> dimensions;
  @Size()
  external int byteLength;
  external Pointer<Uint8> data;
}

@Native<Pointer<Void> Function()>(assetId: _ort, symbol: 'OrtGetApiBase')
external Pointer<Void> ortGetApiBase();

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Size,
    Pointer<Pointer<Void>>,
    Pointer<Uint8>,
    Size,
  )
>(assetId: _shim, symbol: 'zyren_ml_open')
external int nativeOpen(
  Pointer<Void> api,
  Pointer<Uint8> model,
  int length,
  Pointer<Pointer<Void>> session,
  Pointer<Uint8> error,
  int errorLength,
);

@Native<Void Function(Pointer<Void>)>(assetId: _shim, symbol: 'zyren_ml_close')
external void nativeClose(Pointer<Void> session);

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Pointer<Uint8>>,
    Pointer<NativeTensor>,
    Size,
    Pointer<Pointer<Uint8>>,
    Size,
    Pointer<Pointer<Void>>,
    Pointer<Uint8>,
    Size,
  )
>(assetId: _shim, symbol: 'zyren_ml_run')
external int nativeRun(
  Pointer<Void> session,
  Pointer<Pointer<Uint8>> names,
  Pointer<NativeTensor> inputs,
  int count,
  Pointer<Pointer<Uint8>> outputNames,
  int outputCount,
  Pointer<Pointer<Void>> result,
  Pointer<Uint8> error,
  int errorLength,
);

@Native<
  Int32 Function(
    Pointer<Void>,
    Size,
    Pointer<NativeTensor>,
    Pointer<Uint8>,
    Size,
  )
>(assetId: _shim, symbol: 'zyren_ml_result_tensor')
external int nativeResultTensor(
  Pointer<Void> result,
  int index,
  Pointer<NativeTensor> tensor,
  Pointer<Uint8> error,
  int errorLength,
);

@Native<Void Function(Pointer<Void>)>(
  assetId: _shim,
  symbol: 'zyren_ml_result_close',
)
external void nativeResultClose(Pointer<Void> result);

@Native<Int64 Function()>(assetId: _shim, symbol: 'zyren_ml_live_sessions')
external int nativeLiveSessions();
@Native<Int64 Function()>(assetId: _shim, symbol: 'zyren_ml_live_results')
external int nativeLiveResults();

@Native<Int64 Function()>(assetId: _shim, symbol: 'zyren_ml_completed_runs')
external int nativeCompletedRuns();

@Native<Int64 Function()>(assetId: _shim, symbol: 'zyren_ml_active_runs')
external int nativeActiveRuns();

final sessionFinalizer = NativeFinalizer(Native.addressOf(nativeClose));
