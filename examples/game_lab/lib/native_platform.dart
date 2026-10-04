import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_native/surfaces.dart';

/// Selects the existing native presenter for this host.
SceneRuntime gameLabRendering() => Platform.isAndroid
    ? const SceneRuntime.nativeAndroid()
    : Platform.isMacOS || Platform.isIOS
    ? const SceneRuntime.nativeMetal()
    : const SceneRuntime();

/// Existing platform counters include native owners that outlive logical close.
Future<Map<String, int>?> gameLabNativeOwners() async {
  if (!Platform.isAndroid && !Platform.isMacOS && !Platform.isIOS) return null;
  final channel = MethodChannel(
    Platform.isAndroid ? 'zyren/android-surfaces' : 'zyren/scene-views',
  );
  await channel.invokeMethod<void>('connect', {
    'runtime': NativeSurfaces().runtimeToken,
  });
  final values = await channel.invokeMapMethod<Object?, Object?>('diagnostics');
  final keys = Platform.isAndroid
      ? ['sessions', 'surfaces', 'renderers', 'retiring']
      : ['sessions', 'heldDrawables', 'renderers', 'retiring'];
  if (values == null || keys.any((key) => values[key] is! int)) return null;
  return {for (final key in keys) key: values[key] as int};
}
