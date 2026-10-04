import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../waves/sea_state.dart';
import 'wave_render_data.dart';

/// Copies both wave layouts into a shared atlas and blends them in the material.
/// Each endpoint keeps its original texel centers, mip filters and variances.
/// Update both sources to one time, await update(fraction), then render. This
/// object borrows its sources and never advances them or a physical clock.
final class OceanWaveBlend implements OceanWaveRenderInputs {
  final GpuScope _scope;
  final OceanWaveRenderInputs from, to;
  final Map<int, GpuResource<Texture>> _textures;
  final List<(GpuResource<Buffer>, CompiledGraph)> _graphs;
  final int _fromArea;
  @override
  final int resolution, bandCount, logicalPayloadBytes;
  double _seconds = 0, _fraction = 0;
  int _revision = 0, _fromRevision = -1, _toRevision = -1;
  bool _closed = false, _faulted = false;
  Future<void>? _pending, _closing;
  Object? lastFailure;
  Duration lastHostTime = Duration.zero;
  int lastDispatches = 0;
  OceanWaveBlend._(
    this._scope,
    this.from,
    this.to,
    this._textures,
    this._graphs,
    this._fromArea,
    this.resolution,
    this.bandCount,
    this.logicalPayloadBytes,
  );
  @override
  OceanWaveAtlasLayout get atlasLayout => OceanWaveAtlasLayout.blend;
  @override
  OceanSeaState get state => from.state;
  @override
  int get levels => resolution.bitLength;
  @override
  int get texelsPerBand => OceanWaveRenderData.mipTexels(resolution);
  @override
  double get seconds => _seconds;
  double get fraction => _fraction;
  @override
  int get revision => _revision;
  @override
  bool get changesOverTime => true;
  @override
  bool get isClosed => _closed || _scope.isClosed;
  bool _sourceReady(OceanWaveRenderInputs source) =>
      !source.changesOverTime || source.isReady;
  @override
  bool get isReady =>
      !isClosed &&
      !_faulted &&
      _pending == null &&
      _sourceReady(from) &&
      _sourceReady(to) &&
      from.revision == _fromRevision &&
      to.revision == _toRevision;
  @override
  Map<int, GpuResource<Texture>> get textures => Map.unmodifiable(_textures);
  // Blended atlases carry each source variance alongside its layout metadata.
  @override
  Map<int, List<double>> get unresolvedSlopeVariance => Map.unmodifiable({
    for (final id in _textures.keys)
      id: List<double>.unmodifiable(List<double>.filled(bandCount, 0)),
  });

  static ({int width, int height, int bytes}) estimate(
    int fromResolution,
    int fromBands,
    int toResolution,
    int toBands,
    int charts,
  ) {
    final a =
        OceanWaveRenderData.estimateBytes(fromResolution, fromBands, 1) ~/ 16;
    final b = OceanWaveRenderData.estimateBytes(toResolution, toBands, 1) ~/ 16;
    if (charts < 1 || charts > 6) {
      throw ArgumentError('Invalid blend chart count.');
    }
    final width =
        (fromResolution > toResolution ? fromResolution : toResolution) * 4;
    final height = (a + b + 7 + width - 1) ~/ width;
    return (
      width: width,
      height: height,
      bytes: charts * (width * height * 16 + 144),
    );
  }

  static Future<OceanWaveBlend> create(
    GpuScope parent, {
    required OceanWaveRenderInputs from,
    required OceanWaveRenderInputs to,
    double fraction = 0,
    int retainedBytes = 0,
    int maxLogicalBytes = 256 * 1024 * 1024,
  }) async {
    if (!from.isReady ||
        !to.isReady ||
        from.seconds != to.seconds ||
        from.state.revision != to.state.revision ||
        from.atlasLayout != OceanWaveAtlasLayout.packed ||
        to.atlasLayout != OceanWaveAtlasLayout.packed ||
        from.textures.length != to.textures.length ||
        !from.textures.keys.every(to.textures.containsKey) ||
        !fraction.isFinite ||
        fraction < 0 ||
        fraction > 1 ||
        retainedBytes < 0 ||
        maxLogicalBytes < 1 ||
        maxLogicalBytes > 1 << 30) {
      throw ArgumentError(
        'Blend requires ready matching sea states, times and resident charts.',
      );
    }
    final layout = estimate(
      from.resolution,
      from.bandCount,
      to.resolution,
      to.bandCount,
      from.textures.length,
    );
    if (layout.bytes + retainedBytes > maxLogicalBytes ||
        layout.width * layout.height * 16 > 64 * 1024 * 1024) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Wave transition atlases exceed the total or per-texture allowance.',
      );
    }
    final scope = parent.createChild(label: 'ocean-wave-blend');
    try {
      final program = await scope.shaders.compile(
        ShaderSource.wgsl(_copyBlend),
      );
      final textures = <int, GpuResource<Texture>>{},
          graphs = <(GpuResource<Buffer>, CompiledGraph)>[];
      final aArea = 4 * from.resolution * from.resolution * from.bandCount;
      final bArea = 4 * to.resolution * to.resolution * to.bandCount;
      for (final id in from.textures.keys) {
        final work = scope.createChild(label: 'ocean-blend-chart-$id');
        final first = await work.resources.retain(from.textures[id]!);
        final second = await work.resources.retain(to.textures[id]!);
        final uniform = await work.resources.createBuffer(
          BufferDescriptor(
            size: 144,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        final output = await scope.resources.createTexture(
          TextureDescriptor(
            width: layout.width,
            height: layout.height,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.storage},
          ),
        );
        final values = Float32List(36);
        values.setRange(0, 4, [
          from.resolution.toDouble(),
          from.levels.toDouble(),
          from.bandCount.toDouble(),
          from.texelsPerBand.toDouble(),
        ]);
        values.setRange(4, 8, [
          to.resolution.toDouble(),
          to.levels.toDouble(),
          to.bandCount.toDouble(),
          to.texelsPerBand.toDouble(),
        ]);
        values.setRange(
          12,
          12 + from.bandCount,
          from.unresolvedSlopeVariance[id]!,
        );
        values.setRange(20, 20 + to.bandCount, to.unresolvedSlopeVariance[id]!);
        values.setRange(28, 32, [
          layout.width.toDouble(),
          layout.height.toDouble(),
          aArea.toDouble(),
          bArea.toDouble(),
        ]);
        values.setRange(32, 34, [
          (4 * from.resolution).toDouble(),
          (4 * to.resolution).toDouble(),
        ]);
        await work.resources.writeBuffer(uniform, values);
        final graph = await work.graphs.compile(
          GraphDescription(
            inputs: [uniform, first, second],
            passes: [
              ComputePassDescriptor(
                name: 'copy wave transition charts',
                program: program,
                workgroups: Workgroups(
                  (layout.width + 7) ~/ 8,
                  (layout.height + 7) ~/ 8,
                ),
                reads: [uniform, first, second],
                writes: [output],
                bindings: ShaderBindings([
                  BufferBinding.uniform(0, uniform),
                  TextureBinding.sampled(1, first),
                  TextureBinding.sampled(2, second),
                  TextureBinding.storage(3, output),
                ]),
              ),
            ],
          ),
        );
        textures[id] = output;
        graphs.add((await scope.resources.retain(uniform), graph));
      }
      final blend = OceanWaveBlend._(
        scope,
        from,
        to,
        textures,
        graphs,
        aArea,
        from.resolution > to.resolution ? from.resolution : to.resolution,
        from.bandCount > to.bandCount ? from.bandCount : to.bandCount,
        layout.bytes,
      );
      await blend.update(fraction);
      if (parent.isClosed) throw StateError('Wave transition owner closed.');
      return blend;
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  Future<void> update(double fraction) async {
    if (isClosed ||
        _pending != null ||
        !_sourceReady(from) ||
        !_sourceReady(to) ||
        from.seconds != to.seconds) {
      throw StateError(
        'Wave transition sources are busy, closed or have different times.',
      );
    }
    if (!fraction.isFinite || fraction < 0 || fraction > 1) {
      throw ArgumentError('Invalid wave blend fraction.');
    }
    final aRevision = from.revision,
        bRevision = to.revision,
        seconds = from.seconds;
    final done = Completer<void>();
    _pending = done.future;
    final watch = Stopwatch()..start();
    try {
      var dispatches = 0;
      for (final (uniform, graph) in _graphs) {
        // Only the blend metadata changes. Source layouts and variance stay fixed.
        await _scope.resources.writeBuffer(
          uniform,
          Float32List.fromList([fraction, 7, (7 + _fromArea).toDouble(), 0]),
          offset: 32,
        );
        dispatches += (await graph.execute()).dispatches;
      }
      if (!_sourceReady(from) ||
          !_sourceReady(to) ||
          from.revision != aRevision ||
          to.revision != bRevision) {
        throw StateError('Wave transition inputs changed during copy.');
      }
      _fraction = fraction;
      _seconds = seconds;
      _fromRevision = aRevision;
      _toRevision = bRevision;
      _revision++;
      lastDispatches = dispatches;
      lastFailure = null;
      _faulted = false;
    } catch (error) {
      lastFailure = error;
      _faulted = true;
      rethrow;
    } finally {
      watch.stop();
      lastHostTime = watch.elapsed;
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

const _copyBlend = '''
struct Configuration { headers:array<vec4<f32>,7>, output:vec4<f32>, source:vec4<f32> };
@group(0) @binding(0) var<uniform> config:Configuration;
@group(0) @binding(1) var first:texture_2d<f32>;
@group(0) @binding(2) var second:texture_2d<f32>;
@group(0) @binding(3) var output:texture_storage_2d<rgba32float,write>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
  if(id.x>=u32(config.output.x) || id.y>=u32(config.output.y)){return;}
  let index=id.y*u32(config.output.x)+id.x;
  var value=vec4(0.);
  if(index<7u){value=config.headers[index];}
  else if(index<7u+u32(config.output.z)){
    let at=index-7u;let width=u32(config.source.x);
    value=textureLoad(first,vec2<i32>(i32(at%width),i32(at/width)),0);
  }else if(index<7u+u32(config.output.z+config.output.w)){
    let at=index-7u-u32(config.output.z);let width=u32(config.source.y);
    value=textureLoad(second,vec2<i32>(i32(at%width),i32(at/width)),0);
  }
  textureStore(output,vec2<i32>(id.xy),value);
}
''';
