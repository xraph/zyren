part of 'native_renderer.dart';

/// String transport adapter for an existing native host session.
typedef NativeGpuTransport =
    Future<NativeGpuReply> Function(
      String operation,
      Uint8List bytes,
      int responseCapacity,
    );

final class NativeGpuContext extends NativeGpuServices {
  NativeGpuContext(NativeGpuTransport transport)
    : super.withTransport(
        (kind, bytes, capacity) => transport(kind.name, bytes, capacity),
      );
}
