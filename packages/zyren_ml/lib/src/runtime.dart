import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'manifest.dart';
import 'native_bindings.dart';
import 'onnx_validation.dart';
import 'result.dart';
import 'provider.dart';
import 'session.dart';
import 'tensor.dart';

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
    ModelAssetResolver resolver, {
    MlProviderSelection? selection,
  }) async {
    if (selection != null && !selection.matches(model: manifest)) {
      throw const MlLoadException(
        MlRunStatus.unsupported,
        'Provider qualification does not match this model/device or expired.',
      );
    }
    return loadProviderModel(
      manifest,
      resolver,
      provider: selection?.provider ?? 'cpu',
      qualifiedShapes: selection?.inputShapes,
      inputQualification: selection?.accepts,
      providerSelection: selection,
    );
  }

  List<String> get availableProviders => nativeProviders();

  MlNativeDiagnostics get diagnostics => MlNativeDiagnostics(
    liveSessions: nativeLiveSessions(),
    liveResults: nativeLiveResults(),
    completedRuns: nativeCompletedRuns(),
    activeRuns: nativeActiveRuns(),
  );
}

// Internal worker path. Public accelerated loads require a qualification token.
Future<MlSession> loadProviderModel(
  MlModelManifest manifest,
  ModelAssetResolver resolver, {
  String provider = 'cpu',
  String? profilePrefix,
  Map<String, List<int>>? qualifiedShapes,
  bool Function(MlTensorMap)? inputQualification,
  MlProviderSelection? providerSelection,
  DateTime? qualificationDeadline,
}) async {
  if (provider != 'cpu' && provider != 'coreml') {
    throw const MlLoadException(
      MlRunStatus.unsupported,
      'Unknown execution provider.',
    );
  }
  if (manifest.runtimeVersion != MlRuntime.runtimeVersion ||
      manifest.opset != MlRuntime.supportedOpset ||
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
    throw const MlLoadException(MlRunStatus.invalid, 'Model SHA256 mismatch.');
  }
  try {
    validateOnnxEnvelope(bytes, manifest);
    bool expired() =>
        (providerSelection != null &&
            !providerSelection.matches(model: manifest)) ||
        (qualificationDeadline != null &&
            !DateTime.now().isBefore(qualificationDeadline));
    if (expired()) {
      throw const MlLoadException(
        MlRunStatus.unsupported,
        'Provider qualification expired during asset preparation.',
      );
    }
    final session = loadValidatedSession(
      manifest,
      bytes,
      provider: provider,
      profilePrefix: profilePrefix,
      qualifiedShapes: qualifiedShapes,
      inputQualification: inputQualification,
    );
    if (expired()) {
      await session.close();
      throw const MlLoadException(
        MlRunStatus.unsupported,
        'Provider qualification expired during native loading.',
      );
    }
    return session;
  } on MlLoadException {
    rethrow;
  } on FormatException catch (e) {
    throw MlLoadException(MlRunStatus.invalid, e.message);
  } catch (e) {
    throw MlLoadException(MlRunStatus.failed, 'Native model load failed: $e');
  }
}
