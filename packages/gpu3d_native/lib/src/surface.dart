import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:gpu3d/rendering.dart';
import 'surface_bindings.g.dart' as abi;

enum NativeSurfaceState { creating, ready, suspended, closing, closed }

/// Registry identity, never an OS handle or a memory address.
final class NativeSurfaceKey implements SurfaceKey {
  final int _runtime, _slot, _generation;
  const NativeSurfaceKey._(this._runtime, this._slot, this._generation);
  @override
  bool operator ==(Object other) =>
      other is NativeSurfaceKey &&
      _runtime == other._runtime &&
      _slot == other._slot &&
      _generation == other._generation;
  @override
  int get hashCode => Object.hash(_runtime, _slot, _generation);

  abi.Fg2SurfaceKey _record(Arena arena) => abi.Fg2SurfaceKey.$allocate(
    arena,
    struct_size: sizeOf<abi.Fg2SurfaceKey>(),
    abi_version: abi.FG2_ABI_VERSION,
    runtime_token: _runtime,
    slot: _slot,
    generation: _generation,
  ).ref;
}

final class NativeSurfaceSnapshot {
  final NativeSurfaceKey key;
  final int epoch, width, height;
  final NativeSurfaceState state;
  const NativeSurfaceSnapshot._(
    this.key,
    this.epoch,
    this.width,
    this.height,
    this.state,
  );
  int get runtimeToken => key._runtime;
  factory NativeSurfaceSnapshot._read(abi.Fg2SurfaceSnapshot value) =>
      NativeSurfaceSnapshot._(
        NativeSurfaceKey._(
          value.key.runtime_token,
          value.key.slot,
          value.key.generation,
        ),
        value.epoch,
        value.width,
        value.height,
        NativeSurfaceState.values[value.state],
      );
}

final class NativeSurfaceException implements Exception {
  final int code;
  final String message;
  const NativeSurfaceException(this.code, this.message);
  @override
  String toString() => 'NativeSurfaceException($code): $message';
}

/// Reserves metadata for a platform adapter. Reservation alone cannot present.
final class NativeSurfaces {
  int get runtimeToken => abi.fg2_runtime_token();

  NativeSurfaceSnapshot reserve({
    required int width,
    required int height,
    int bufferLimit = 3,
    int maxInFlight = 1,
    int memoryLimit = 64 * 1024 * 1024,
  }) {
    _extent(width, height);
    if (bufferLimit < 2 ||
        bufferLimit > 3 ||
        maxInFlight < 1 ||
        maxInFlight > 2 ||
        maxInFlight > bufferLimit ||
        memoryLimit < 1 ||
        memoryLimit > 256 * 1024 * 1024) {
      throw ArgumentError('Invalid native surface capacity.');
    }
    return _call(
      (arena, output, error) => abi.fg2_surface_create(
        abi.Fg2SurfaceDescriptor.$allocate(
          arena,
          struct_size: sizeOf<abi.Fg2SurfaceDescriptor>(),
          abi_version: abi.FG2_ABI_VERSION,
          width: width,
          height: height,
          buffer_limit: bufferLimit,
          max_in_flight: maxInFlight,
          memory_limit: memoryLimit,
        ),
        output,
        error,
      ),
    );
  }

  NativeSurfaceSnapshot resize(
    NativeSurfaceSnapshot surface, {
    required int width,
    required int height,
  }) {
    _extent(width, height);
    return _call(
      (arena, output, error) => abi.fg2_surface_resize(
        surface.key._record(arena),
        surface.epoch,
        width,
        height,
        output,
        error,
      ),
    );
  }

  NativeSurfaceSnapshot suspend(
    NativeSurfaceSnapshot surface, {
    required bool suspended,
  }) => _call(
    (arena, output, error) => abi.fg2_surface_suspend(
      surface.key._record(arena),
      surface.epoch,
      suspended ? 1 : 0,
      output,
      error,
    ),
  );
  NativeSurfaceSnapshot close(NativeSurfaceSnapshot surface) => _call(
    (arena, output, error) =>
        abi.fg2_surface_close(surface.key._record(arena), output, error),
  );

  static void _extent(int width, int height) {
    if (width < 1 || height < 1 || width > 4096 || height > 4096) {
      throw ArgumentError('Surface dimensions must be between 1 and 4096.');
    }
  }

  NativeSurfaceSnapshot _call(
    int Function(Arena, Pointer<abi.Fg2SurfaceSnapshot>, Pointer<abi.Fg2Error>)
    operation,
  ) => using((arena) {
    final output = arena<abi.Fg2SurfaceSnapshot>();
    output.ref.struct_size = sizeOf<abi.Fg2SurfaceSnapshot>();
    output.ref.abi_version = abi.FG2_ABI_VERSION;
    final error = arena<abi.Fg2Error>();
    error.ref.struct_size = sizeOf<abi.Fg2Error>();
    error.ref.abi_version = abi.FG2_ABI_VERSION;
    final status = operation(arena, output, error);
    if (status != 0) {
      final length = error.ref.message_length.clamp(0, 240);
      throw NativeSurfaceException(
        status,
        utf8.decode([
          for (var i = 0; i < length; i++) error.ref.message[i],
        ], allowMalformed: true),
      );
    }
    return NativeSurfaceSnapshot._read(output.ref);
  });
}
