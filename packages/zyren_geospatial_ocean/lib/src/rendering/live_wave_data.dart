part of 'wave_render_data.dart';

/// Mutable visual atlas backed by persistent native FFT and packing graphs.
/// Await update before using dependent materials, captures or foam producers.
/// This stream never mutates the canonical sea state or a physical sampler.
final class OceanWaveStream implements OceanWaveRenderInputs {
  final GpuScope _scope;
  @override
  final OceanSeaState state;
  @override
  final int resolution, bandCount, logicalPayloadBytes;
  @override
  final Map<int, GpuResource<Texture>> textures;
  @override
  final Map<int, List<double>> unresolvedSlopeVariance;
  final Map<int, _LiveChart> _charts;
  double _seconds;
  int _revision = 0, _lastDispatches = 0;
  Duration _lastHostTime = Duration.zero;
  bool _closed = false, _faulted = false;
  Object? lastFailure;
  Future<void>? _pending, _closing;
  OceanWaveStream._(
    this._scope,
    this.state,
    this.resolution,
    this.bandCount,
    this.logicalPayloadBytes,
    this._seconds,
    Map<int, GpuResource<Texture>> textures,
    Map<int, List<double>> variance,
    this._charts,
  ) : textures = Map.unmodifiable(textures),
      unresolvedSlopeVariance = Map.unmodifiable(variance);
  @override
  int get levels => resolution.bitLength;
  @override
  int get texelsPerBand => OceanWaveRenderData.mipTexels(resolution);
  @override
  double get seconds => _seconds;
  @override
  int get revision => _revision;
  @override
  bool get changesOverTime => true;
  @override
  bool get isClosed => _closed || _scope.isClosed;
  @override
  bool get isReady => !isClosed && _pending == null && !_faulted;
  int get lastDispatches => _lastDispatches;
  Duration get lastHostTime => _lastHostTime;
  int get packedPayloadBytes =>
      OceanWaveRenderData.estimateBytes(resolution, bandCount, _charts.length);
  int get hostCoefficientBytes =>
      state.canonicalResolution *
      state.canonicalResolution *
      state.bands.length *
      24 *
      _charts.length;

  static int estimateBytes(int resolution, int bands, int charts) =>
      OceanWaveRenderData.estimateBytes(resolution, bands, charts) +
      charts *
          (OceanWaveFieldGpu.estimateBytes(resolution, bands) +
              _OceanWavePacking.estimateBytes(resolution, bands));

  static Future<OceanWaveStream> create(
    GpuScope parent, {
    required OceanSeaState state,
    required Iterable<int> chartIds,
    required int resolution,
    int? bandCount,
    double seconds = 0,
    int maxLogicalBytes = 256 * 1024 * 1024,
    int retainedBytes = 0,
  }) async {
    final ids = chartIds.take(7).toList()..sort();
    final bands = bandCount ?? state.bands.length;
    if (ids.isEmpty ||
        ids.length > 6 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => id < 0 || id > 5) ||
        bands < 1 ||
        bands > state.bands.length ||
        resolution > state.canonicalResolution ||
        !seconds.isFinite ||
        seconds.abs() > 1e12 ||
        retainedBytes < 0 ||
        maxLogicalBytes < 1 ||
        maxLogicalBytes > 1 << 30) {
      throw ArgumentError('Invalid live wave layout, time or allowance.');
    }
    final bytes = estimateBytes(resolution, bands, ids.length);
    if (bytes + retainedBytes > maxLogicalBytes ||
        OceanWaveRenderData.estimateBytes(resolution, bands, 1) >
            64 * 1024 * 1024) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Live wave fields, atlases and packing scratch exceed the allowance.',
      );
    }
    final scope = parent.createChild(label: 'ocean-live-waves');
    try {
      final copy = await scope.shaders.compile(ShaderSource.wgsl(_copy));
      final mip = await scope.shaders.compile(ShaderSource.wgsl(_mip));
      final store = await scope.shaders.compile(ShaderSource.wgsl(_store));
      final charts = <int, _LiveChart>{},
          textures = <int, GpuResource<Texture>>{},
          variance = <int, List<double>>{};
      for (final id in ids) {
        final field = await OceanWaveFieldGpu.create(
          scope,
          oceanChartSeaState(state, id),
          maxLogicalBytes: OceanWaveFieldGpu.estimateBytes(resolution, bands),
        );
        final atlas = await scope.resources.createTexture(
          TextureDescriptor(
            label: 'ocean-live-chart-$id',
            width: resolution * 4,
            height: resolution * bands,
            format: TextureFormat.rgba32Float,
            usage: {
              TextureUsage.storage,
              TextureUsage.sampled,
              TextureUsage.copySource,
            },
          ),
        );
        final pack = await _OceanWavePacking.create(
          scope.createChild(label: 'ocean-live-pack-$id'),
          resolution,
          bands,
          atlas,
          copy,
          mip,
          store,
        );
        final graphs = <Object, CompiledGraph>{};
        // Warm both native publication slots. Subsequent updates reuse these
        // exact bindings and the same scratch/configuration allocations.
        for (var slot = 0; slot < 2; slot++) {
          final source = await field.evaluate(
            seconds,
            resolution: resolution,
            bandCount: bands,
          );
          final graph = await pack.compile(source);
          await graph.execute();
          graphs[source.bands.first.displacement.allocationIdentity] = graph;
          variance[id] = List.unmodifiable([
            for (var band = 0; band < bands; band++)
              source.bands[band].unresolvedSlopeVariance +
                  (band == 0 ? source.omittedBandSlopeVariance : 0),
          ]);
        }
        if (graphs.length != 2) {
          throw StateError('Live waves require two stable publication slots.');
        }
        textures[id] = atlas;
        charts[id] = _LiveChart(field, graphs);
      }
      if (parent.isClosed) {
        throw StateError('Live wave owner closed during creation.');
      }
      return OceanWaveStream._(
        scope,
        state,
        resolution,
        bands,
        bytes,
        seconds,
        textures,
        variance,
        charts,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  /// Complete canonical re-evaluation can recover a failed update. Until that
  /// succeeds, isReady is false because published textures may be incomplete.
  /// Consumers must not render or retain a live stream while it is updating.
  Future<void> update(double seconds) async {
    if (isClosed || _pending != null) {
      throw StateError('Live waves are closed or busy.');
    }
    if (!seconds.isFinite || seconds.abs() > 1e12) {
      throw ArgumentError('Invalid live wave time.');
    }
    final done = Completer<void>();
    _pending = done.future;
    final watch = Stopwatch()..start();
    try {
      var dispatches = 0;
      for (final chart in _charts.values) {
        final source = await chart.field.evaluate(
          seconds,
          resolution: resolution,
          bandCount: bandCount,
        );
        final graph =
            chart.graphs[source.bands.first.displacement.allocationIdentity];
        if (graph == null) {
          throw StateError(
            'Live wave source storage changed. Recreate the stream.',
          );
        }
        dispatches += source.dispatches + (await graph.execute()).dispatches;
      }
      _seconds = seconds;
      _revision++;
      _lastDispatches = dispatches;
      lastFailure = null;
      _faulted = false;
    } catch (error) {
      _faulted = true;
      lastFailure = error;
      rethrow;
    } finally {
      watch.stop();
      _lastHostTime = watch.elapsed;
      _pending = null;
      done.complete();
    }
  }

  /// Explicit qualification readback. Never used by the animation path.
  Future<Float32List> debugRead(
    int chart, {
    int band = 0,
    int level = 0,
  }) async {
    if (!isReady) throw StateError('Live wave input is not ready.');
    RangeError.checkValueInInterval(band, 0, bandCount - 1, 'band');
    RangeError.checkValueInInterval(level, 0, levels - 1, 'level');
    final texture = textures[chart];
    if (texture == null) throw ArgumentError('Chart is not resident.');
    final done = Completer<void>();
    _pending = done.future;
    try {
      var offset = band * texelsPerBand, n = resolution;
      for (var i = 0; i < level; i++) {
        offset += n * n;
        n ~/= 2;
      }
      final data = ByteData.sublistView(
        await _scope.resources.readTexture(texture),
      );
      return Float32List.fromList([
        for (var i = offset * 48; i < (offset + n * n) * 48; i += 4)
          data.getFloat32(i, Endian.little),
      ]);
    } finally {
      _pending = null;
      done.complete();
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _pending;
    await _scope.close();
  }
}

final class _LiveChart {
  final OceanWaveFieldGpu field;
  final Map<Object, CompiledGraph> graphs;
  _LiveChart(this.field, this.graphs);
}
