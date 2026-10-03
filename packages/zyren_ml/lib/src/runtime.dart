import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'manifest.dart';
import 'native_bindings.dart';
import 'onnx_validation.dart';
import 'result.dart';
import 'session.dart';

/// The host owns assets, scope and cache policy. Return the named bundle bytes.
typedef ModelAssetResolver = Future<Uint8List> Function(String path);

final class MlNativeDiagnostics {
  const MlNativeDiagnostics({
    required this.liveSessions,
    required this.liveResults,
    required this.completedRuns,
    required this.activeRuns,
  });
  final int liveSessions;
  final int liveResults;
  final int completedRuns;
  final int activeRuns;
}

final class MlRuntime {
  const MlRuntime();
  static const runtimeVersion = '1.23.2';
  static const supportedOpset = 17;

  Future<MlSession> load(
    MlModelManifest manifest,
    ModelAssetResolver resolver,
  ) async {
    if (manifest.runtimeVersion != runtimeVersion ||
        manifest.opset != supportedOpset ||
        manifest.providers.any((p) => p != 'cpu') ||
        manifest.customOperatorLibraries.isNotEmpty ||
        manifest.externalData.isNotEmpty) {
      throw const MlLoadException(
        MlRunStatus.unsupported,
        'A1 requires runtime 1.23.2, opset 17, CPU and embedded standard operators.',
      );
    }
    Uint8List bytes;
    try {
      // Copy once, preventing resolver mutations during hash/native validation.
      bytes = Uint8List.fromList(await resolver(manifest.modelFile));
    } catch (e) {
      throw MlLoadException(
        MlRunStatus.unavailable,
        'Model asset resolution failed: $e',
      );
    }
    if (bytes.isEmpty || bytes.length > manifest.maxModelBytes) {
      throw const MlLoadException(
        MlRunStatus.invalid,
        'Model exceeds manifest byte limit.',
      );
    }
    if (crypto.sha256.convert(bytes).toString() != manifest.sha256) {
      throw const MlLoadException(
        MlRunStatus.invalid,
        'Model SHA256 mismatch.',
      );
    }
    try {
      validateOnnxEnvelope(bytes, manifest);
      return loadValidatedSession(manifest, bytes);
    } on MlLoadException {
      rethrow;
    } on FormatException catch (e) {
      throw MlLoadException(MlRunStatus.invalid, e.message);
    } catch (e) {
      throw MlLoadException(MlRunStatus.failed, 'Native model load failed: $e');
    }
  }

  MlNativeDiagnostics get diagnostics => MlNativeDiagnostics(
    liveSessions: nativeLiveSessions(),
    liveResults: nativeLiveResults(),
    completedRuns: nativeCompletedRuns(),
    activeRuns: nativeActiveRuns(),
  );
}
