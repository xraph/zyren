import 'dart:ffi';

const _asset = 'package:zyren_physics/src/bindings.dart';
@Native<Pointer<Char> Function(Pointer<Char>)>(
  symbol: 'zyren_physics_call',
  assetId: _asset,
)
external Pointer<Char> physicsCall(Pointer<Char> input);
@Native<Void Function(Pointer<Char>)>(
  symbol: 'zyren_physics_free',
  assetId: _asset,
)
external void physicsFree(Pointer<Char> output);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'zyren_physics_finalize',
  assetId: _asset,
)
external void physicsFinalize(Pointer<Void> token);
