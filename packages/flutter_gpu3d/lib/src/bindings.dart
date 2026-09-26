import 'dart:ffi';

const _asset = 'package:flutter_gpu3d/src/bindings.dart';

@Native<Uint32 Function()>(symbol: 'fg_abi_version', assetId: _asset)
external int abiVersion();
@Native<Uint64 Function()>(symbol: 'fg_create', assetId: _asset)
external int create();
@Native<Uint32 Function(Uint64)>(symbol: 'fg_destroy', assetId: _asset)
external int destroy(int handle);
@Native<Void Function(Pointer<Void>)>(symbol: 'fg_finalize', assetId: _asset)
external void finalize(Pointer<Void> token);
@Native<Size Function(Pointer<Uint8>, Size)>(
  symbol: 'fg_last_error',
  assetId: _asset,
)
external int lastError(Pointer<Uint8> buffer, int capacity);
@Native<
  Uint32 Function(
    Uint64,
    Pointer<Uint8>,
    Size,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'fg_render', assetId: _asset)
external int render(
  int handle,
  Pointer<Uint8> json,
  int jsonLength,
  int width,
  int height,
  Pointer<Uint8> pixels,
  int capacity,
);
