import 'package:zyren_native/zyren_native.dart';

// Asset retention checks exclude draw uniforms, whose payload has separate
// telemetry and is charged to the same registry. Never subtract upload bytes.
Future<int> sceneAssetPayloadBytes(NativeBackend backend) async {
  final total = (await backend.resourceStats()).residentBytes;
  final uniforms =
      (await backend.inspectGpu()).frameProfile?.drawCacheUniformBytes ?? 0;
  if (uniforms > total) {
    throw StateError('Draw payload exceeds registry payload');
  }
  return total - uniforms;
}
