import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../waves/spectrum.dart';
import 'canonical.dart';
import 'query_wgsl.dart';

/// Numerical envelope relative to the canonical field, excluding model error.
final class OceanFieldError {
  final double height, displacement, slope, displacementGradient, velocity;
  const OceanFieldError(
    this.height,
    this.displacement,
    this.slope,
    this.displacementGradient,
    this.velocity,
  );
}

final class OceanCanonicalGpuBatch {
  final String seaStateRevision;
  final double seconds;
  final List<OceanReferenceSample> values;
  final List<OceanFieldError> errors;
  final int dispatches;
  OceanCanonicalGpuBatch._(
    this.seaStateRevision,
    this.seconds,
    Iterable<OceanReferenceSample> values,
    Iterable<OceanFieldError> errors,
    this.dispatches,
  ) : values = List.unmodifiable(values),
      errors = List.unmodifiable(errors);
}

/// Sparse physical field evaluation. It never consumes a visual FFT grid.
final class OceanCanonicalGpu {
  final GpuScope _scope;
  final int maxSamples, maxModes, maxLogicalBytes;
  late ShaderProgram _shader;
  _QueryBuffers? _active;
  Completer<void>? _pending;
  Future<void>? _closing;
  bool _closed = false;
  Object? _lastRetirementFailure;
  Object? get lastRetirementFailure => _lastRetirementFailure;
  OceanCanonicalGpu._(
    this._scope,
    this.maxSamples,
    this.maxModes,
    this.maxLogicalBytes,
  );
  static Future<OceanCanonicalGpu> create(
    GpuScope parent, {
    int maxSamples = 256,
    int maxModes = 262144,
    int maxLogicalBytes = 128 * 1024 * 1024,
  }) async {
    if (maxSamples < 1 ||
        maxSamples > 4096 ||
        maxModes < 1 ||
        maxModes > 2097152 ||
        maxLogicalBytes < 1 ||
        maxLogicalBytes > 1 << 30) {
      throw ArgumentError('Invalid native ocean query limits.');
    }
    final scope = parent.createChild(label: 'ocean-canonical-query');
    final result = OceanCanonicalGpu._(
      scope,
      maxSamples,
      maxModes,
      maxLogicalBytes,
    );
    try {
      result._shader = await scope.shaders.compile(
        ShaderSource.wgsl(oceanCanonicalQueryWgsl),
      );
      return result;
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  int get logicalPayloadBytes => _active?.bytes ?? 0;
  void _check(LoadCancellation? cancellation) {
    if (_closed || _scope.isClosed) {
      throw StateError('Native ocean queries have closed.');
    }
    cancellation?.throwIfCancelled();
  }

  Future<OceanCanonicalGpuBatch> sample(
    OceanCanonicalSnapshot snapshot,
    List<(double, double)> points, {
    LoadCancellation? cancellation,
  }) async {
    _check(cancellation);
    if (_pending != null) {
      throw StateError('Await the accepted ocean query batch first.');
    }
    if (points.isEmpty ||
        points.length > maxSamples ||
        snapshot.modeCount > maxModes ||
        points.any(
          (p) =>
              !p.$1.isFinite ||
              !p.$2.isFinite ||
              p.$1.abs() > 1e12 ||
              p.$2.abs() > 1e12,
        )) {
      throw ArgumentError(
        'Native query batch exceeds its coordinate or work limits.',
      );
    }
    if (snapshot.modes.any((v) => v.abs() > 1e20)) {
      throw ArgumentError(
        'Canonical modes exceed native query numeric limits.',
      );
    }
    final done = Completer<void>();
    _pending = done;
    try {
      final buffers = await _prepare(snapshot, cancellation);
      _check(cancellation);
      final bands = snapshot.state.bands.length,
          coordinates = Float32List(points.length * bands * 2),
          phaseErrors = <double>[];
      const epsilon = 1.1920928955078125e-7;
      for (var p = 0; p < points.length; p++) {
        var error = 0.0;
        for (var band = 0; band < bands; band++) {
          final period = snapshot.state.bands[band].patchMetres,
              u = (points[p].$1 % period) / period,
              v = (points[p].$2 % period) / period,
              index = 2 * (p * bands + band);
          coordinates[index] = u;
          coordinates[index + 1] = v;
          final quantization =
              (coordinates[index] - u).abs() +
              (coordinates[index + 1] - v).abs();
          error = math.max(
            error,
            2 *
                math.pi *
                (snapshot.state.canonicalResolution *
                        (quantization + 4 * epsilon) +
                    4 * epsilon),
          );
        }
        phaseErrors.add(error);
      }
      await buffers.scope.resources.writeBuffer(
        buffers.coordinates,
        coordinates,
      );
      await buffers.scope.resources.writeBuffer(
        buffers.config,
        Uint32List.fromList([snapshot.modeCount, points.length, bands, 0]),
      );
      _check(cancellation);
      final stats = await buffers.graph.execute();
      _check(cancellation);
      final bytes = await buffers.scope.resources.readBuffer(
        buffers.output,
        length: points.length * 48,
      );
      _check(cancellation);
      final data = ByteData.sublistView(bytes),
          values = <OceanReferenceSample>[],
          errors = <OceanFieldError>[];
      for (var p = 0; p < points.length; p++) {
        final fields = [
          for (var c = 0; c < 12; c++)
            data.getFloat32(p * 48 + c * 4, Endian.little),
        ];
        fields[0] += snapshot.state.meanLevel;
        values.add(oceanSampleFromValues(fields));
        errors.add(_error(snapshot, phaseErrors[p]));
      }
      return OceanCanonicalGpuBatch._(
        snapshot.seaStateRevision,
        snapshot.seconds,
        values,
        errors,
        stats.dispatches,
      );
    } finally {
      _pending = null;
      done.complete();
    }
  }

  OceanFieldError _error(OceanCanonicalSnapshot field, double phase) {
    if (field.modeCount == 0) return const OceanFieldError(0, 0, 0, 0, 0);
    const epsilon = 1.1920928955078125e-7, trig = 1 / 2048;
    final additions = (field.modeCount + 63) ~/ 64 + 6;
    final gamma = additions * epsilon / (1 - additions * epsilon);
    final relative = 2 * (trig + phase) + 24 * epsilon + 2 * gamma,
        e = field.envelope;
    // Covers coefficient quantization, arithmetic, trig, lane sums and reduction.
    return OceanFieldError(
      relative * e.height + 1e-10,
      relative * e.displacement + 1e-10,
      relative * e.slope + 1e-10,
      relative * e.displacementGradient + 1e-10,
      relative * e.velocity + 1e-10,
    );
  }

  Future<_QueryBuffers> _prepare(
    OceanCanonicalSnapshot snapshot,
    LoadCancellation? cancellation,
  ) async {
    final previous = _active, bands = snapshot.state.bands.length;
    var capacity = 1;
    while (capacity < snapshot.modeCount) {
      capacity *= 2;
    }
    capacity = math.min(capacity, maxModes);
    final replacement =
        previous == null ||
        previous.modeCapacity < capacity ||
        previous.bands != bands;
    var current = previous;
    if (replacement) {
      final bytes =
          capacity * 48 + maxSamples * bands * 8 + maxSamples * 48 + 16;
      if (bytes + logicalPayloadBytes > maxLogicalBytes) {
        throw const ResourceException(
          ResourceErrorCode.budgetExceeded,
          'Native canonical query replacement exceeds its logical allowance.',
        );
      }
      final scope = _scope.createChild(label: 'canonical-query-buffers');
      try {
        final modes = await _buffer(scope, capacity * 48),
            coordinates = await _buffer(scope, maxSamples * bands * 8),
            output = await _buffer(scope, maxSamples * 48);
        final config = await scope.resources.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        _check(cancellation);
        final graph = await scope.graphs.compile(
          GraphDescription(
            label: 'canonical-ocean-query',
            inputs: {modes, coordinates, output, config},
            passes: [
              ComputePassDescriptor(
                name: 'canonical-ocean-samples',
                program: _shader,
                workgroups: Workgroups(maxSamples),
                reads: [modes, coordinates, output, config],
                writes: [output],
                bindings: ShaderBindings([
                  BufferBinding.uniform(0, config),
                  BufferBinding.storageRead(1, modes),
                  BufferBinding.storageRead(2, coordinates),
                  BufferBinding.storageReadWrite(3, output),
                ]),
              ),
            ],
          ),
        );
        current = _QueryBuffers(
          scope,
          capacity,
          bands,
          bytes,
          modes,
          coordinates,
          output,
          config,
          graph,
        );
      } catch (_) {
        await scope.close();
        rethrow;
      }
    }
    try {
      final candidate = current!,
          key = (snapshot.seaStateRevision, snapshot.seconds);
      if (candidate.uploadedKey != key) {
        if (snapshot.modeCount > 0) {
          await candidate.scope.resources.writeBuffer(
            candidate.modes,
            Float32List.fromList(snapshot.modes),
          );
        }
        _check(cancellation);
        candidate.uploadedKey = key;
      }
      if (replacement) {
        _active = candidate;
        if (previous != null) {
          try {
            await previous.scope.close();
          } catch (error) {
            _lastRetirementFailure = error;
          }
        }
      }
      return candidate;
    } catch (_) {
      if (replacement && current != null && !identical(current, _active)) {
        await current.scope.close();
      }
      rethrow;
    }
  }

  Future<GpuResource<Buffer>> _buffer(GpuScope scope, int bytes) =>
      scope.resources.createBuffer(
        BufferDescriptor(
          size: bytes,
          usage: {
            BufferUsage.storage,
            BufferUsage.copySource,
            BufferUsage.copyDestination,
          },
        ),
      );
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _pending?.future;
    await _scope.close();
    _active = null;
  }
}

final class _QueryBuffers {
  final GpuScope scope;
  final int modeCapacity, bands, bytes;
  final GpuResource<Buffer> modes, coordinates, output, config;
  final CompiledGraph graph;
  (String, double)? uploadedKey;
  _QueryBuffers(
    this.scope,
    this.modeCapacity,
    this.bands,
    this.bytes,
    this.modes,
    this.coordinates,
    this.output,
    this.config,
    this.graph,
  );
}
