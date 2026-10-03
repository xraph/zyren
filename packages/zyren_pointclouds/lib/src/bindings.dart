import 'dart:ffi';

const _asset = 'package:zyren_pointclouds/src/bindings.dart';
@Native<Uint64 Function()>(symbol: 'zyren_points_job_create', assetId: _asset)
external int pointsJobCreate();
@Native<Void Function(Uint64)>(
  symbol: 'zyren_points_job_cancel',
  assetId: _asset,
)
external void pointsJobCancel(int id);
@Native<Void Function(Uint64)>(symbol: 'zyren_points_job_free', assetId: _asset)
external void pointsJobFree(int id);
@Native<
  Pointer<Uint8> Function(
    Uint64,
    Pointer<Uint8>,
    Size,
    Size,
    Size,
    Pointer<Size>,
  )
>(symbol: 'zyren_points_decode', assetId: _asset)
external Pointer<Uint8> pointsDecode(
  int id,
  Pointer<Uint8> input,
  int length,
  int maxPoints,
  int maxBytes,
  Pointer<Size> outputLength,
);
@Native<Void Function(Pointer<Uint8>, Size)>(
  symbol: 'zyren_points_free',
  assetId: _asset,
)
external void pointsFree(Pointer<Uint8> output, int length);
