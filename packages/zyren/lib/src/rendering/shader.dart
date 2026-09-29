part of '../resources/resource_scope.dart';

/// WGSL source and its diagnostic label. Construction allocates no GPU state.
final class ShaderSource {
  static const maxByteLength = 1024 * 1024;
  static const maxLabelByteLength = 1024;
  final String code, label;
  ShaderSource.wgsl(this.code, {this.label = ''}) {
    if (code.isEmpty ||
        code.length > maxByteLength ||
        utf8.encode(code).length > maxByteLength) {
      throw ArgumentError('WGSL source must contain 1 byte to 1 MiB of UTF-8.');
    }
    if (label.length > maxLabelByteLength ||
        utf8.encode(label).length > maxLabelByteLength) {
      throw ArgumentError('Shader labels must fit 1024 UTF-8 bytes.');
    }
  }
}

enum ShaderStage { vertex, fragment, compute }

enum ShaderDiagnosticSeverity { info, warning, error }

enum ShaderErrorCode {
  invalidSource,
  unsupportedFeature,
  limitExceeded,
  staleProgram,
  deviceFailed,
  invalidCommand,
}

/// One-based line and column, with zero-based offset and length in UTF-16 units.
/// These positions index Dart strings, including source containing Unicode.
final class ShaderLocation {
  final int line, column, offset, length;
  const ShaderLocation({
    required this.line,
    required this.column,
    required this.offset,
    required this.length,
  });
}

final class ShaderDiagnostic {
  final String message;
  final ShaderDiagnosticSeverity severity;
  final ShaderLocation? location;
  const ShaderDiagnostic({
    required this.message,
    required this.severity,
    this.location,
  });
}

final class ShaderEntryPoint {
  final String name;
  final ShaderStage stage;
  final (int, int, int)? workgroupSize;
  const ShaderEntryPoint({
    required this.name,
    required this.stage,
    this.workgroupSize,
  });
}

final class ShaderCompilationException extends SceneException {
  final ShaderSource source;
  final ShaderErrorCode code;
  final List<ShaderDiagnostic> diagnostics;
  factory ShaderCompilationException(
    ShaderSource source,
    Iterable<ShaderDiagnostic> diagnostics, {
    ShaderErrorCode code = ShaderErrorCode.invalidSource,
  }) => ShaderCompilationException._(
    source,
    List.unmodifiable(diagnostics),
    code,
  );
  ShaderCompilationException._(this.source, this.diagnostics, this.code)
    : super(
        SceneIssue(
          code: 'shader.${code.name}',
          operation: 'compile',
          resourceLabel: source.label,
          message: diagnostics.isEmpty
              ? 'Shader compilation failed.'
              : diagnostics.first.message,
        ),
      );
}

/// A validated native module. Pipeline compilation also checks stage interfaces,
/// resource bindings and target formats when this program is used by a graph.
final class ShaderProgram {
  final ShaderCompiler _compiler;
  final Object _key;
  final ShaderSource source;
  final List<ShaderEntryPoint> entryPoints;
  final List<ShaderDiagnostic> diagnostics;
  ShaderProgram._(
    this._compiler,
    this._key,
    this.source,
    Iterable<ShaderEntryPoint> entryPoints,
    Iterable<ShaderDiagnostic> diagnostics,
  ) : entryPoints = List.unmodifiable(entryPoints),
      diagnostics = List.unmodifiable(diagnostics);
  bool get isClosed => _compiler.isClosed;
}
