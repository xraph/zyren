import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'incremental.dart';

const pipelinePreparationVersion =
    'zyren-pipeline-prepare/1;meshopt=0.6.2;basisu_c_sys=0.9.1';

enum PipelineTextureProfile { etc1s, uastc }

final class PipelinePreparedMesh {
  final String sourceId;
  final GeometryData geometry;

  /// Output triangle to original triangle. Null for topology-changing LODs.
  final List<int>? sourceTriangles;
  final List<String>? triangleSourceIds;
  final double absoluteError, cacheAcmrBefore, cacheAcmrAfter;
  final int inputIndexBytes, outputIndexBytes;
  final String? protectionReason;
  PipelinePreparedMesh._({
    required this.sourceId,
    required this.geometry,
    required this.sourceTriangles,
    required this.triangleSourceIds,
    required this.absoluteError,
    required this.cacheAcmrBefore,
    required this.cacheAcmrAfter,
    required this.inputIndexBytes,
    required this.outputIndexBytes,
    required this.protectionReason,
  });

  /// Quadric object-space error, not a Hausdorff, posed-animation or pixel bound.
  String get errorMethod => 'meshoptimizer-quadric-object-space';
}

final class PipelinePreparedTexture {
  final Uint8List ktx2;
  final PipelineTextureProfile profile;
  final int sourceBytes;

  /// Validated using the host-selected decoder and its target format.
  final TextureImageData decoded;
  PipelinePreparedTexture._(
    Uint8List bytes,
    this.profile,
    this.sourceBytes,
    this.decoded,
  ) : ktx2 = Uint8List.fromList(bytes).asUnmodifiableView();
}

/// One-shot pinned CPU workers. The executable is a trusted host configuration,
/// never an agent argument. Cancellation kills and drains its process.
final class PipelinePreparer {
  final String executable;
  final Duration timeout;
  final int maxInputBytes, maxOutputBytes, maxActiveJobs;
  int _active = 0;
  PipelinePreparer({
    required this.executable,
    this.timeout = const Duration(minutes: 2),
    this.maxInputBytes = 96 * 1024 * 1024,
    this.maxOutputBytes = 96 * 1024 * 1024,
    this.maxActiveJobs = 2,
  }) {
    if (executable.isEmpty ||
        timeout <= Duration.zero ||
        maxInputBytes < 1 ||
        maxInputBytes > 96 * 1024 * 1024 ||
        maxOutputBytes < 1 ||
        maxActiveJobs < 1 ||
        maxActiveJobs > 8) {
      throw ArgumentError('Invalid preparation worker limits.');
    }
  }
  int get activeJobs => _active;

  /// Prepare one material/source primitive. Vertices, all attributes and morph
  /// deltas retain their exact values and indices. Never merge material seams.
  /// Skin/morph and per-face identity inputs permit only lossless reordering.
  Future<PipelinePreparedMesh> mesh({
    required GeometrySnapshot geometry,
    required String sourceId,
    double? ratio,
    double maxError = 0,
    List<int> lockedVertices = const [],
    List<String>? triangleSourceIds,
    LoadCancellation? cancellation,
  }) async {
    if (sourceId.isEmpty ||
        sourceId.length > 2048 ||
        geometry.topology != GeometryTopology.triangles ||
        !maxError.isFinite ||
        maxError < 0 ||
        (ratio != null && (!ratio.isFinite || ratio <= 0 || ratio > 1)) ||
        lockedVertices.any((i) => i < 0 || i >= geometry.layout.vertexCount) ||
        (triangleSourceIds != null &&
            (triangleSourceIds.length != geometry.primitiveCount ||
                triangleSourceIds.any(
                  (id) => id.isEmpty || id.length > 2048,
                )))) {
      throw ArgumentError('Invalid mesh preparation request.');
    }
    final identities = triangleSourceIds == null
        ? null
        : List<String>.unmodifiable(triangleSourceIds);
    final protection =
        geometry.joints != null || geometry.morphTargets.isNotEmpty
        ? 'deformation-preserved'
        : identities != null
        ? 'face-identities-preserved'
        : null;
    final attributes = <double>[];
    final channels = [
      geometry.normals,
      if (geometry.uv0 != null) geometry.uv0!,
      if (geometry.uv1 != null) geometry.uv1!,
      if (geometry.colors != null) geometry.colors!,
      if (geometry.tangents != null) geometry.tangents!,
    ];
    final count = geometry.layout.vertexCount;
    for (var i = 0; i < count; i++) {
      for (final channel in channels) {
        final components = channel.length ~/ count;
        attributes.addAll(
          channel.getRange(i * components, (i + 1) * components),
        );
      }
    }
    final output = await _run({
      'operation': 'mesh',
      'positions': geometry.positions,
      'indices': geometry.indices,
      'locked': lockedVertices,
      'attributes': attributes,
      'weights': List.filled(
        channels.fold<int>(0, (sum, c) => sum + c.length ~/ count),
        1.0,
      ),
      'ratio': protection == null ? ratio : null,
      'max_error': maxError,
    }, cancellation);
    final indices = (output['indices'] as List).cast<int>();
    final data = GeometryData(
      attributes: geometry.attributes,
      indices: indices,
      indexFormat: geometry.indexFormat,
      morphTargets: geometry.morphTargets,
    );
    final error = (output['absoluteError'] as num).toDouble();
    if (!error.isFinite ||
        error < 0 ||
        error > maxError + 1e-6 ||
        output['vertexDataChanged'] != false ||
        indices.length > geometry.indices.length) {
      throw const FormatException('Invalid mesh preparation result.');
    }
    final unchanged =
        ratio == null ||
        protection != null ||
        indices.length == geometry.indices.length;
    final mapping = unchanged ? _triangleMap(geometry.indices, indices) : null;
    return PipelinePreparedMesh._(
      sourceId: sourceId,
      geometry: data,
      sourceTriangles: mapping,
      triangleSourceIds: identities == null
          ? null
          : List.unmodifiable(mapping!.map((i) => identities[i])),
      absoluteError: error,
      cacheAcmrBefore: (output['cacheAcmrBefore'] as num).toDouble(),
      cacheAcmrAfter: (output['cacheAcmrAfter'] as num).toDouble(),
      inputIndexBytes:
          geometry.indices.length * geometry.indexFormat.bytesPerIndex,
      outputIndexBytes: indices.length * geometry.indexFormat.bytesPerIndex,
      protectionReason: ratio != null ? protection : null,
    );
  }

  /// Every level derives from the original geometry so errors do not accumulate.
  Future<List<PipelinePreparedMesh>> lods({
    required GeometrySnapshot geometry,
    required String sourceId,
    required List<double> ratios,
    required double maxError,
    LoadCancellation? cancellation,
  }) async {
    if (ratios.isEmpty ||
        ratios.length > 8 ||
        ratios.any((r) => !r.isFinite || r <= 0 || r >= 1)) {
      throw ArgumentError(
        'Choose one to eight LOD ratios between zero and one.',
      );
    }
    final levels = <PipelinePreparedMesh>[];
    for (final ratio in List<double>.of(ratios)) {
      levels.add(
        await mesh(
          geometry: geometry,
          sourceId: sourceId,
          ratio: ratio,
          maxError: maxError,
          cancellation: cancellation,
        ),
      );
    }
    return List.unmodifiable(levels);
  }

  /// Input is tightly packed, top-left, straight-alpha RGBA8. Basis clamp mips
  /// filter channels independently; alpha coverage preservation is not claimed.
  /// Keep source pixels as an original bundle resource for future rebuilds.
  Future<PipelinePreparedTexture> texture({
    required Uint8List rgba,
    required int width,
    required int height,
    required bool srgb,
    required TextureDecoder decoder,
    PipelineTextureProfile profile = PipelineTextureProfile.uastc,
    bool mipmaps = true,
    int quality = 75,
    int effort = 2,
    ImageDecodeLimits decodeLimits = const ImageDecodeLimits(),
    LoadCancellation? cancellation,
  }) async {
    if (width < 1 ||
        height < 1 ||
        width > 4096 ||
        height > 4096 ||
        rgba.length != width * height * 4 ||
        quality < 1 ||
        quality > 100 ||
        effort < 0 ||
        effort > 10) {
      throw ArgumentError('Invalid texture preparation request.');
    }
    final output = await _run({
      'operation': 'texture',
      'width': width,
      'height': height,
      'rgba': base64Encode(rgba),
      'srgb': srgb,
      'mipmaps': mipmaps,
      'format': profile.name,
      'quality': quality,
      'effort': effort,
    }, cancellation);
    final bytes = base64Decode(output['ktx2'] as String);
    cancellation?.throwIfCancelled();
    final decoded = await decoder.decode(
      bytes,
      encoding: TextureEncoding.ktx2Basis,
      limits: decodeLimits,
    );
    cancellation?.throwIfCancelled();
    final descriptor = decoded.descriptor;
    if (descriptor.width != width ||
        descriptor.height != height ||
        descriptor.format.isSrgb != srgb ||
        descriptor.mipLevels !=
            (mipmaps ? (width > height ? width : height).bitLength : 1)) {
      throw const FormatException(
        'Prepared texture changed its extent, transfer or mip chain.',
      );
    }
    return PipelinePreparedTexture._(bytes, profile, rgba.length, decoded);
  }

  Future<Map<String, dynamic>> _run(
    Map<String, Object?> request,
    LoadCancellation? cancellation,
  ) async {
    final token = cancellation ?? PipelineCancellation();
    token.throwIfCancelled();
    if (_active >= maxActiveJobs) {
      throw StateError('Preparation worker budget is full.');
    }
    final input = utf8.encode(jsonEncode(request));
    if (input.length > maxInputBytes) {
      throw const FormatException('Preparation input budget exceeded.');
    }
    _active++;
    try {
      final process = await Process.start(
        executable,
        const [],
        runInShell: false,
      );
      var timedOut = false, exceeded = false;
      void kill() {
        process.kill(ProcessSignal.sigkill);
      }

      final registration = token.onCancel(kill);
      final timer = Timer(timeout, () {
        timedOut = true;
        kill();
      });
      final stdout = BytesBuilder(copy: false),
          stderr = BytesBuilder(copy: false);
      Future<void> drain(
        Stream<List<int>> stream,
        BytesBuilder target,
        int limit,
      ) async {
        await for (final chunk in stream) {
          if (target.length + chunk.length > limit) {
            exceeded = true;
            kill();
          } else {
            target.add(chunk);
          }
        }
      }

      final output = drain(process.stdout, stdout, maxOutputBytes);
      final errors = drain(process.stderr, stderr, 16384);
      try {
        try {
          process.stdin.add(input);
          await process.stdin.close();
        } on IOException {
          /* The worker may have been cancelled before consuming input. */
        }
        final code = await process.exitCode;
        await Future.wait([output, errors]);
        token.throwIfCancelled();
        if (timedOut) {
          throw TimeoutException('Preparation worker timed out.', timeout);
        }
        if (exceeded) {
          throw const FormatException('Preparation output budget exceeded.');
        }
        if (code != 0) {
          throw const FormatException('Native preparation failed.');
        }
        final result = jsonDecode(utf8.decode(stdout.takeBytes()));
        if (result is! Map<String, dynamic> ||
            result['toolVersion'] != pipelinePreparationVersion) {
          throw const FormatException('Preparation tool version mismatch.');
        }
        return result;
      } finally {
        timer.cancel();
        registration.dispose();
        kill();
      }
    } finally {
      _active--;
    }
  }
}

List<int> _triangleMap(List<int> before, List<int> after) {
  final occurrences = <String, List<int>>{};
  String key(List<int> indices, int offset) =>
      '${indices[offset]},${indices[offset + 1]},${indices[offset + 2]}';
  for (var i = 0; i < before.length; i += 3) {
    occurrences.putIfAbsent(key(before, i), () => []).add(i ~/ 3);
  }
  final result = <int>[];
  for (var i = 0; i < after.length; i += 3) {
    final matches = occurrences[key(after, i)];
    if (matches == null || matches.isEmpty) {
      throw const FormatException('Lossless preparation changed triangles.');
    }
    result.add(matches.removeLast());
  }
  return List.unmodifiable(result);
}
