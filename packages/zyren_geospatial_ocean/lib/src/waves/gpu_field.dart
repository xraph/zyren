import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'sea_state.dart';
import 'spectrum.dart';
import 'fft_plan.dart';
import 'fft_wgsl.dart';
import 'spectrum_wgsl.dart';
import 'field_snapshot.dart';

/// Owns native compute work below the supplied scope. Evaluations are exclusive;
/// a candidate publishes only after every band finishes. Failed candidates leave
/// the current textures and canonical sea state intact.
final class OceanWaveFieldGpu {
  final OceanSeaState state;
  final GpuScope _scope;
  final int maxLogicalBytes;
  late final OceanSpectrum _spectrum = OceanSpectrum(state);
  late ShaderProgram _fft, _evolution, _pack;
  _FieldSet? _active;
  OceanFieldSnapshot? _snapshot;
  int _revision = 0;
  bool _closed = false;
  Future<void>? _pending, _closing;
  OceanWaveFieldGpu._(this._scope, this.state, this.maxLogicalBytes);
  Object? _lastRetirementFailure;
  Object? get lastRetirementFailure => _lastRetirementFailure;
  OceanFieldSnapshot? get current => _snapshot;
  int get logicalPayloadBytes => _active?.bytes ?? 0;
  static Future<OceanWaveFieldGpu> create(
    GpuScope parent,
    OceanSeaState state, {
    int maxLogicalBytes = 256 * 1024 * 1024,
  }) async {
    if (maxLogicalBytes < 1 || maxLogicalBytes > 1 << 30) {
      throw ArgumentError('Invalid ocean GPU allowance.');
    }
    final scope = parent.createChild(label: 'ocean-wave-field');
    final field = OceanWaveFieldGpu._(scope, state, maxLogicalBytes);
    try {
      field._fft = await scope.shaders.compile(ShaderSource.wgsl(oceanFftWgsl));
      field._evolution = await scope.shaders.compile(
        ShaderSource.wgsl(oceanSpectrumWgsl),
      );
      field._pack = await scope.shaders.compile(
        ShaderSource.wgsl(oceanPackWgsl),
      );
      return field;
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  static int estimateBytes(int resolution, int bands) {
    final plan = OceanFftPlan(resolution);
    if (bands < 1 || bands > 8) throw ArgumentError('Invalid band count.');
    return bands *
        (208 * resolution * resolution + 16 * (plan.stages.length + 1));
  }

  void _check(LoadCancellation token) {
    if (_closed || _scope.isClosed) {
      throw StateError('Ocean wave field has closed.');
    }
    token.throwIfCancelled();
  }

  Future<T> _exclusive<T>(Future<T> Function() work) {
    if (_closed || _scope.isClosed) {
      return Future.error(StateError('Ocean wave field has closed.'));
    }
    if (_pending != null) {
      return Future.error(
        StateError('Await the active ocean evaluation first.'),
      );
    }
    final done = Completer<T>();
    _pending = done.future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    unawaited(
      Future.sync(work).then<void>(
        (value) {
          _pending = null;
          done.complete(value);
        },
        onError: (Object e, StackTrace s) {
          _pending = null;
          done.completeError(e, s);
        },
      ),
    );
    return done.future;
  }

  Future<OceanFieldSnapshot> evaluate(
    double seconds, {
    required int resolution,
    LoadCancellation? cancellation,
  }) => _exclusive(() async {
    final token = cancellation ?? LoadCancellationSource();
    _check(token);
    if (!seconds.isFinite ||
        seconds.abs() > 1e12 ||
        resolution > state.canonicalResolution) {
      throw ArgumentError(
        'Evaluation exceeds the canonical resolution or time range.',
      );
    }
    final bytes = estimateBytes(resolution, state.bands.length);
    final replacement = _active == null || _active!.size != resolution;
    if (bytes + (replacement ? logicalPayloadBytes : 0) > maxLogicalBytes) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Ocean replacement exceeds its logical byte allowance.',
      );
    }
    _FieldSet? candidate;
    try {
      candidate = replacement
          ? await _build(resolution, bytes, token)
          : _active!;
      _check(token);
      await _setTime(candidate, seconds, token);
      final slot = candidate.slot == 0 ? 1 : 0;
      final stats = await candidate.graphs[slot].execute();
      _check(token);
      final previous = _active;
      _active = candidate;
      candidate.slot = slot;
      final revision = ++_revision;
      final snapshot = OceanFieldSnapshot(
        bands: candidate.outputs[slot],
        seconds: seconds,
        meanLevel: state.meanLevel,
        seaStateRevision: state.revision,
        revision: revision,
        resolution: resolution,
        logicalPayloadBytes: bytes,
        dispatches: stats.dispatches,
        isCurrent: () => !_closed && !_scope.isClosed && _revision == revision,
      );
      _snapshot = snapshot;
      if (replacement && previous != null) {
        try {
          await previous.scope.close();
        } catch (error) {
          // Publication succeeded. The parent scope retains cleanup failures
          // and reports them on close; do not label this usable field failed.
          _lastRetirementFailure = error;
        }
      }
      return snapshot;
    } catch (_) {
      if (replacement && candidate != null && !identical(candidate, _active)) {
        await candidate.scope.close();
      }
      rethrow;
    }
  });
  Future<_FieldSet> _build(int size, int bytes, LoadCancellation token) async {
    final scope = _scope.createChild(label: 'ocean-grid-$size');
    final value = _FieldSet(scope, size, bytes);
    try {
      final passes = [<PassDescriptor>[], <PassDescriptor>[]];
      final inputs = <GpuResource<Object?>>{};
      for (var band = 0; band < state.bands.length; band++) {
        _check(token);
        final seeds = await _buffer(scope, size * size * 16);
        final first = await _buffer(scope, size * size * 6 * 8);
        final second = await _buffer(scope, size * size * 6 * 8);
        final config = await scope.resources.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        final data = _BandWork(seeds, config);
        value.bands.add(data);
        final evolution = ComputePassDescriptor(
          name: 'ocean-evolve-$band',
          program: _evolution,
          workgroups: Workgroups((size + 7) ~/ 8, (size + 7) ~/ 8),
          reads: [config, seeds, first],
          writes: [first],
          bindings: ShaderBindings([
            BufferBinding.uniform(0, config),
            BufferBinding.storageRead(1, seeds),
            BufferBinding.storageReadWrite(2, first),
          ]),
        );
        final fft = await OceanFftPlan(size).build(
          scope,
          _fft,
          first,
          second,
          channels: 6,
          prefix: 'ocean-$band-fft',
        );
        final variance = _missingVariance(band, size);
        for (var slot = 0; slot < 2; slot++) {
          final output = OceanBandTextures(
            displacement: await _texture(scope, size),
            derivatives: await _texture(scope, size),
            velocity: await _texture(scope, size),
            patchMetres: state.bands[band].patchMetres,
            unresolvedSlopeVariance: variance,
          );
          value.outputs[slot].add(output);
          passes[slot].addAll([
            evolution,
            ...fft,
            ComputePassDescriptor(
              name: 'ocean-pack-$band',
              program: _pack,
              workgroups: Workgroups((size + 7) ~/ 8, (size + 7) ~/ 8),
              reads: [config, first],
              writes: [
                output.displacement,
                output.derivatives,
                output.velocity,
              ],
              bindings: ShaderBindings([
                BufferBinding.uniform(0, config),
                BufferBinding.storageRead(1, first),
                TextureBinding.storage(2, output.displacement),
                TextureBinding.storage(3, output.derivatives),
                TextureBinding.storage(4, output.velocity),
              ]),
            ),
          ]);
        }
        inputs.addAll([
          seeds,
          first,
          second,
          config,
          ...fft.expand((p) => p.reads),
        ]);
      }
      for (var slot = 0; slot < 2; slot++) {
        _check(token);
        final graphScope = scope.createChild(label: 'ocean-output-$slot');
        value.graphs.add(
          await graphScope.graphs.compile(
            GraphDescription(
              label: 'ocean-grid-$size-output-$slot',
              passes: passes[slot],
              inputs: inputs,
            ),
          ),
        );
      }
      return value;
    } catch (_) {
      await scope.close();
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
  Future<GpuResource<Texture>> _texture(GpuScope scope, int size) =>
      scope.resources.createTexture(
        TextureDescriptor(
          width: size,
          height: size,
          format: TextureFormat.rgba32Float,
          usage: {
            TextureUsage.storage,
            TextureUsage.sampled,
            TextureUsage.copySource,
          },
        ),
      );
  double _missingVariance(int band, int size) {
    final canonical = state.canonicalResolution,
        h = _spectrum.coefficients[band];
    final step = 2 * math.pi / state.bands[band].patchMetres;
    var variance = 0.0;
    for (var z = 0; z < canonical; z++) {
      for (var x = 0; x < canonical; x++) {
        final nx = oceanFrequencyIndex(x, canonical),
            nz = oceanFrequencyIndex(z, canonical);
        if (nx.abs() < size ~/ 2 && nz.abs() < size ~/ 2) continue;
        final i = 2 * (z * canonical + x);
        variance +=
            2 *
            (h[i] * h[i] + h[i + 1] * h[i + 1]) *
            step *
            step *
            (nx * nx + nz * nz) /
            (canonical * canonical * canonical * canonical);
      }
    }
    if (!variance.isFinite) {
      throw ArgumentError('Unresolved slope variance exceeds finite range.');
    }
    return variance;
  }

  late final double _anchorSpan = () {
    final maximum = _spectrum.frequencies.expand((f) => f).fold(0.0, math.max);
    final limit = maximum == 0 ? 32.0 : math.min(32.0, 32 / maximum);
    return math.pow(2, (math.log(limit) / math.ln2).floor()).toDouble();
  }();
  Future<void> _setTime(
    _FieldSet value,
    double seconds,
    LoadCancellation token,
  ) async {
    final anchor = (seconds / _anchorSpan).floor() * _anchorSpan,
        size = value.size,
        canonical = state.canonicalResolution;
    for (var band = 0; band < value.bands.length; band++) {
      _check(token);
      final work = value.bands[band], b = state.bands[band];
      if (work.anchor != anchor) {
        final h = _spectrum.coefficients[band],
            omega = _spectrum.frequencies[band];
        final upload = Float32List(size * size * 4),
            scale = size * size / (canonical * canonical);
        for (var z = 0; z < size; z++) {
          for (var x = 0; x < size; x++) {
            final nx = oceanFrequencyIndex(x, size),
                nz = oceanFrequencyIndex(z, size);
            final source = (nz % canonical) * canonical + nx % canonical,
                i = 4 * (z * size + x);
            final w = omega[source];
            if (x != size ~/ 2 && z != size ~/ 2) {
              if (h[2 * source].abs() / (canonical * canonical) > 1e6 ||
                  h[2 * source + 1].abs() / (canonical * canonical) > 1e6) {
                throw ArgumentError(
                  'Wave coefficients exceed the native numerical allowance.',
                );
              }
              upload[i] = h[2 * source] * scale;
              upload[i + 1] = h[2 * source + 1] * scale;
            }
            upload[i + 2] = w;
            upload[i + 3] = w == 0 ? 0 : -(anchor % (2 * math.pi / w)) * w;
          }
        }
        if (upload.any((v) => !v.isFinite)) {
          throw ArgumentError(
            'Canonical coefficients exceed native Float32 range.',
          );
        }
        await value.scope.resources.writeBuffer(work.seeds, upload);
        work.anchor = anchor;
      }
      await value.scope.resources.writeBuffer(
        work.config,
        Float32List.fromList([
          size.toDouble(),
          2 * math.pi / b.patchMetres,
          b.choppiness,
          seconds - anchor,
        ]),
      );
    }
  }

  /// Explicit numerical readback, never used by the render loop.
  Future<Float32List> debugInverse(
    Float64List coefficients, {
    required int size,
  }) => _exclusive(() async {
    final plan = OceanFftPlan(size);
    if (size > 32 ||
        coefficients.length != 2 * size * size ||
        coefficients.any((v) => !v.isFinite || v.abs() > 1e20)) {
      throw ArgumentError(
        'Debug inverse requires a finite grid no larger than 32.',
      );
    }
    if (logicalPayloadBytes +
            coefficients.length * 8 +
            plan.stages.length * 16 >
        maxLogicalBytes) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Debug inverse exceeds the ocean allowance.',
      );
    }
    final input = Float32List.fromList(coefficients);
    final scope = _scope.createChild(label: 'ocean-debug-inverse');
    try {
      final first = await _buffer(scope, coefficients.length * 4),
          second = await _buffer(scope, coefficients.length * 4);
      await scope.resources.writeBuffer(first, input);
      final passes = await plan.build(scope, _fft, first, second);
      final graph = await scope.graphs.compile(
        GraphDescription(
          passes: passes,
          inputs: {first, second, ...passes.expand((p) => p.reads)},
        ),
      );
      await graph.execute();
      return _floats(await scope.resources.readBuffer(first));
    } finally {
      await scope.close();
    }
  });
  Future<
    ({Float32List displacement, Float32List derivatives, Float32List velocity})
  >
  debugRead(
    OceanFieldSnapshot snapshot, {
    int band = 0,
  }) => _exclusive(() async {
    if (!identical(snapshot, _snapshot) || !snapshot.isCurrent) {
      throw StateError('The ocean snapshot is no longer current.');
    }
    RangeError.checkValidIndex(band, snapshot.bands);
    final textures = snapshot.bands[band], resources = _active!.scope.resources;
    return (
      displacement: _floats(await resources.readTexture(textures.displacement)),
      derivatives: _floats(await resources.readTexture(textures.derivatives)),
      velocity: _floats(await resources.readTexture(textures.velocity)),
    );
  });
  static Float32List _floats(Uint8List bytes) {
    final data = ByteData.sublistView(bytes),
        result = Float32List(bytes.length ~/ 4);
    for (var i = 0; i < result.length; i++) {
      result[i] = data.getFloat32(i * 4, Endian.little);
    }
    return result.asUnmodifiableView();
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await _pending;
    await _scope.close();
    _active = null;
    _snapshot = null;
  }
}

final class _BandWork {
  final GpuResource<Buffer> seeds, config;
  double? anchor;
  _BandWork(this.seeds, this.config);
}

final class _FieldSet {
  final GpuScope scope;
  final int size, bytes;
  int slot = -1;
  final bands = <_BandWork>[];
  final outputs = [<OceanBandTextures>[], <OceanBandTextures>[]];
  final graphs = <CompiledGraph>[];
  _FieldSet(this.scope, this.size, this.bytes);
}
