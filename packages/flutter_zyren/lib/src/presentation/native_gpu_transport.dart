import 'dart:typed_data';
import 'package:zyren/zyren.dart' show ScopeCleanupException;
import 'package:zyren_native/zyren_native.dart';

/// Uses the presenter's existing session and native rendering queue.
NativeGpuServices nativeGpuServices(
  Future<Map> Function(Map<String, Object> arguments) request,
) => NativeGpuServices.withTransport((kind, bytes, capacity) async {
  final reply = await request({
    'kind': kind.name,
    'bytes': bytes,
    'capacity': capacity,
  });
  final status = reply['status'] as int;
  return status == 0
      ? NativeGpuReply.success(reply['bytes'] as Uint8List)
      : NativeGpuReply.failure(status, reply['message'] as String);
});

Future<void> closeNativeGpuServices(
  NativeGpuServices services,
  Future<void> Function() closeSession,
  Future<void>? drawing,
) async {
  final failures = <(Object, StackTrace)>[];
  try {
    await services.close();
  } catch (error, stack) {
    failures.add((error, stack));
  }
  await Future.wait<void>([
    Future<void>.sync(closeSession).then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        failures.add((error, stack));
      },
    ),
    ?drawing,
  ]);
  if (failures.length == 1) {
    Error.throwWithStackTrace(failures.single.$1, failures.single.$2);
  }
  if (failures.isNotEmpty) {
    throw ScopeCleanupException(failures.map((e) => e.$1));
  }
}
