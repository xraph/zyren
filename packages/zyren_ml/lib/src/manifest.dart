import 'dart:convert';

import 'tensor.dart';

/// A relative bundle path, independent of filesystem or asset-cache ownership.
void validateModelAssetPath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('\u0000') ||
      path.split('/').any((p) => p.isEmpty || p == '.' || p == '..') ||
      Uri.decodeComponent(path) != path) {
    throw FormatException('Model asset must be a plain relative bundle path.');
  }
}

final class MlTensorSpec {
  MlTensorSpec({
    required this.name,
    required this.dtype,
    required List<int> shape,
    required List<int> maxShape,
  }) : shape = List.unmodifiable(shape),
       maxShape = List.unmodifiable(maxShape) {
    if (name.isEmpty ||
        name.contains('\u0000') ||
        shape.length != maxShape.length ||
        shape.length > 8) {
      throw FormatException('Invalid tensor name or rank.');
    }
    for (var i = 0; i < shape.length; i++) {
      if ((shape[i] != -1 && shape[i] <= 0) ||
          maxShape[i] <= 0 ||
          (shape[i] != -1 && shape[i] != maxShape[i])) {
        throw FormatException(
          'Tensor dimensions need fixed sizes or bounded -1.',
        );
      }
    }
    mlTensorByteLength(dtype, maxShape);
  }

  factory MlTensorSpec.fromJson(Map<String, dynamic> json) => MlTensorSpec(
    name: json['name'] as String,
    dtype: MlDtype.values.byName(json['dtype'] as String),
    shape: (json['shape'] as List).cast<int>(),
    maxShape: (json['maxShape'] as List).cast<int>(),
  );

  final String name;
  final MlDtype dtype;
  final List<int> shape;
  final List<int> maxShape;

  bool accepts(MlTensor tensor) {
    if (tensor.dtype != dtype || tensor.shape.length != shape.length) {
      return false;
    }
    for (var i = 0; i < shape.length; i++) {
      if (tensor.shape[i] > maxShape[i] ||
          (shape[i] != -1 && tensor.shape[i] != shape[i])) {
        return false;
      }
    }
    return tensor.isFinite;
  }

  Map<String, Object> toJson() => {
    'name': name,
    'dtype': dtype.name,
    'shape': shape,
    'maxShape': maxShape,
  };
}

final class MlModelManifest {
  MlModelManifest({
    this.schemaVersion = 1,
    required this.id,
    required this.modelFile,
    required this.sha256,
    required this.opset,
    this.runtimeVersion = '1.23.2',
    List<String> providers = const ['cpu'],
    this.maxModelBytes = 8 * 1024 * 1024,
    required List<MlTensorSpec> inputs,
    required List<MlTensorSpec> outputs,
    Map<String, String> recurrent = const {},
    this.provenance = '',
    Map<String, dynamic> preprocessing = const {},
    List<String> customOperatorLibraries = const [],
    List<String> externalData = const [],
  }) : providers = List.unmodifiable(providers),
       inputs = List.unmodifiable(inputs),
       outputs = List.unmodifiable(outputs),
       recurrent = Map.unmodifiable(recurrent),
       preprocessing = _freezeMetadata(preprocessing) as Map<String, dynamic>,
       customOperatorLibraries = List.unmodifiable(customOperatorLibraries),
       externalData = List.unmodifiable(externalData) {
    validateModelAssetPath(modelFile);
    for (final path in externalData) {
      validateModelAssetPath(path);
    }
    if (schemaVersion != 1 ||
        id.isEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        opset <= 0 ||
        maxModelBytes <= 0 ||
        maxModelBytes > mlMaxTensorBytes ||
        providers.isEmpty ||
        inputs.isEmpty ||
        outputs.isEmpty ||
        inputs.length > 64 ||
        outputs.length > 64) {
      throw FormatException('Invalid model manifest schema, hash or limits.');
    }
    for (final specs in [inputs, outputs]) {
      if (specs.map((t) => t.name).toSet().length != specs.length) {
        throw FormatException('Tensor names must be unique.');
      }
      final total = specs.fold<int>(
        0,
        (n, t) => n + mlTensorByteLength(t.dtype, t.maxShape),
      );
      if (total > mlMaxTensorBytes) {
        throw FormatException('Tensor set exceeds 64 MiB.');
      }
    }
    for (final entry in recurrent.entries) {
      final input = inputs.where((t) => t.name == entry.key).firstOrNull;
      final output = outputs.where((t) => t.name == entry.value).firstOrNull;
      if (input == null ||
          output == null ||
          input.dtype != output.dtype ||
          jsonEncode(input.shape) != jsonEncode(output.shape) ||
          jsonEncode(input.maxShape) != jsonEncode(output.maxShape)) {
        throw FormatException(
          'Recurrent tensors must have matching input/output specs.',
        );
      }
    }
    if (recurrent.values.toSet().length != recurrent.length) {
      throw FormatException('Recurrent outputs must be unique.');
    }
  }

  factory MlModelManifest.decode(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    return MlModelManifest(
      schemaVersion: j['schemaVersion'] as int,
      id: j['id'] as String,
      modelFile: j['modelFile'] as String,
      sha256: j['sha256'] as String,
      opset: j['opset'] as int,
      runtimeVersion: j['runtimeVersion'] as String,
      providers: (j['providers'] as List).cast<String>(),
      maxModelBytes: j['maxModelBytes'] as int,
      inputs: (j['inputs'] as List)
          .map((t) => MlTensorSpec.fromJson(t as Map<String, dynamic>))
          .toList(),
      outputs: (j['outputs'] as List)
          .map((t) => MlTensorSpec.fromJson(t as Map<String, dynamic>))
          .toList(),
      recurrent: (j['recurrent'] as Map).cast<String, String>(),
      provenance: j['provenance'] as String? ?? '',
      preprocessing: j['preprocessing'] as Map<String, dynamic>? ?? {},
      customOperatorLibraries: (j['customOperatorLibraries'] as List? ?? [])
          .cast<String>(),
      externalData: (j['externalData'] as List? ?? []).cast<String>(),
    );
  }

  final int schemaVersion;
  final String id;
  final String modelFile;
  final String sha256;
  final int opset;
  final String runtimeVersion;
  final List<String> providers;
  final int maxModelBytes;
  final List<MlTensorSpec> inputs;
  final List<MlTensorSpec> outputs;
  final Map<String, String> recurrent;
  final String provenance;
  final Map<String, dynamic> preprocessing;
  final List<String> customOperatorLibraries;
  final List<String> externalData;

  String encode() => jsonEncode({
    'schemaVersion': schemaVersion,
    'id': id,
    'modelFile': modelFile,
    'sha256': sha256,
    'opset': opset,
    'runtimeVersion': runtimeVersion,
    'providers': providers,
    'maxModelBytes': maxModelBytes,
    'inputs': inputs.map((t) => t.toJson()).toList(),
    'outputs': outputs.map((t) => t.toJson()).toList(),
    'recurrent': recurrent,
    'provenance': provenance,
    'preprocessing': preprocessing,
    'customOperatorLibraries': customOperatorLibraries,
    'externalData': externalData,
  });
}

Object? _freezeMetadata(Object? value, [int depth = 0]) {
  if (depth > 32) {
    throw const FormatException('Preprocessing metadata nesting exceeds 32.');
  }
  if (value == null ||
      value is String ||
      value is bool ||
      value is num && value.isFinite) {
    return value;
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(
      value.map((v) => _freezeMetadata(v, depth + 1)),
    );
  }
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, v) => MapEntry(key, _freezeMetadata(v, depth + 1))),
    );
  }
  throw const FormatException(
    'Preprocessing metadata must contain finite JSON values.',
  );
}
