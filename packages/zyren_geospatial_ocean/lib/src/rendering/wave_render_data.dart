import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../surface/wave_chart.dart';
import '../waves/sea_state.dart';
import '../waves/field_snapshot.dart';

/// The same chart seed mapping used by canonical physical sampling.
OceanSeaState oceanChartSeaState(OceanSeaState state, int chart) =>
    OceanSeaState(
      seed: OceanWaveCharts(seed: state.seed).seedFor(chart),
      canonicalResolution: state.canonicalResolution,
      bands: state.bands,
      gravity: state.gravity,
      density: state.density,
      meanLevel: state.meanLevel,
      spectrum: state.spectrum,
    );

/// An immutable native copy of one evaluated time, with periodic box-filtered
/// levels. Each texel contains three vec4s: displacement/Jacobian, derivatives,
/// and (cross derivative, mean squared height slope, 0, 0). Velocity remains in
/// the independent simulation/query fields. No production readback is required.
final class OceanWaveRenderData {
  final GpuScope _scope;
  final OceanSeaState state;
  final int resolution, levels, texelsPerBand, logicalPayloadBytes;
  final double seconds;
  final Map<int, GpuResource<Buffer>> buffers;
  final Map<int, List<double>> unresolvedSlopeVariance;
  bool get isClosed => _scope.isClosed;
  OceanWaveRenderData._(
    this._scope,
    this.state,
    this.resolution,
    this.seconds,
    Map<int, GpuResource<Buffer>> buffers,
    Map<int, List<double>> variance,
    this.logicalPayloadBytes,
  ) : buffers = Map.unmodifiable(buffers),
      unresolvedSlopeVariance = Map.unmodifiable(variance),
      levels = resolution.bitLength,
      texelsPerBand = mipTexels(resolution);

  static int mipTexels(int resolution) {
    if (resolution < 4 ||
        resolution > 512 ||
        resolution & (resolution - 1) != 0) {
      throw ArgumentError('Visual wave grids must be dyadic in 4..512.');
    }
    return (4 * resolution * resolution - 1) ~/ 3;
  }

  static int estimateBytes(int resolution, int bands, int charts) {
    if (bands < 1 || bands > 8 || charts < 1 || charts > 6) {
      throw ArgumentError('Invalid visual chart or band count.');
    }
    return mipTexels(resolution) * bands * charts * 48;
  }

  /// Caller-provided charts must belong to [state], share one time/resolution,
  /// and remain current until packing completes. A failed candidate closes all
  /// resources. Include other retained candidates in [retainedBytes] admission.
  static Future<OceanWaveRenderData> pack(
    GpuScope parent, {
    required OceanSeaState state,
    required Map<int, OceanFieldSnapshot> charts,
    int maxLogicalBytes = 256 * 1024 * 1024,
    int retainedBytes = 0,
    LoadCancellation? cancellation,
  }) async {
    final input = Map<int, OceanFieldSnapshot>.of(charts);
    if (input.isEmpty ||
        input.length > 6 ||
        maxLogicalBytes < 1 ||
        maxLogicalBytes > 1 << 30 ||
        retainedBytes < 0) {
      throw ArgumentError('Invalid packed wave admission.');
    }
    final first = input.values.first, size = first.resolution;
    final bytes = estimateBytes(size, state.bands.length, input.length);
    final perChart = bytes ~/ input.length;
    // One temporary 16-byte dispatch config per mip and band is also admitted.
    final transient = size.bitLength * state.bands.length * 16;
    if (bytes + transient + retainedBytes > maxLogicalBytes ||
        perChart > 64 * 1024 * 1024) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Packed visual waves exceed the total or per-buffer allowance.',
      );
    }
    void check() {
      cancellation?.throwIfCancelled();
      if (parent.isClosed) throw StateError('Visual wave owner closed.');
      for (final entry in input.entries) {
        final source = entry.value;
        if (!source.isCurrent) throw StateError('Visual wave source is stale.');
        if (source.resolution != size ||
            source.seconds != first.seconds ||
            source.seaStateRevision !=
                oceanChartSeaState(state, entry.key).revision ||
            source.bands.length != state.bands.length) {
          throw ArgumentError(
            'Visual wave charts do not match their physical state/time.',
          );
        }
      }
    }

    check();
    final scope = parent.createChild(label: 'ocean-visual-waves');
    final buffers = <int, GpuResource<Buffer>>{};
    try {
      final compiler = scope.createChild(label: 'ocean-visual-pack-work');
      try {
        final copy = await compiler.shaders.compile(ShaderSource.wgsl(_copy));
        final mip = await compiler.shaders.compile(ShaderSource.wgsl(_mip));
        for (final entry in input.entries) {
          check();
          final output = await scope.resources.createBuffer(
            BufferDescriptor(
              label: 'ocean-visual-chart-${entry.key}',
              size: perChart,
              usage: {BufferUsage.storage, BufferUsage.copySource},
            ),
          );
          buffers[entry.key] = output;
          final work = compiler.createChild(label: 'ocean-pack-chart');
          try {
            final passes = <PassDescriptor>[];
            final inputs = <GpuResource<Object?>>{output};
            Future<GpuResource<Buffer>> config(
              int n,
              int source,
              int dest,
            ) async {
              final b = await work.resources.createBuffer(
                BufferDescriptor(
                  size: 16,
                  usage: {BufferUsage.uniform, BufferUsage.copyDestination},
                ),
              );
              await work.resources.writeBuffer(
                b,
                Uint32List.fromList([n, source, dest, 0]),
              );
              inputs.add(b);
              return b;
            }

            for (var band = 0; band < state.bands.length; band++) {
              final base = band * mipTexels(size) * 3;
              final source = entry.value.bands[band];
              final textures = <GpuResource<Texture>>[];
              for (final t in [
                source.displacement,
                source.derivatives,
                source.velocity,
              ]) {
                textures.add(await work.resources.retain(t));
              }
              inputs.addAll(textures);
              final settings = await config(size, 0, base);
              passes.add(
                ComputePassDescriptor(
                  name: 'copy-band-$band',
                  program: copy,
                  workgroups: Workgroups((size + 7) ~/ 8, (size + 7) ~/ 8),
                  reads: [settings, ...textures, output],
                  writes: [output],
                  bindings: ShaderBindings([
                    BufferBinding.uniform(0, settings),
                    BufferBinding.storageReadWrite(1, output),
                    for (var i = 0; i < 3; i++)
                      TextureBinding.sampled(2 + i, textures[i]),
                  ]),
                ),
              );
              var n = size, from = base, to = base + size * size * 3;
              for (var level = 1; level < size.bitLength; level++) {
                final settings = await config(n, from, to);
                final target = n ~/ 2;
                passes.add(
                  ComputePassDescriptor(
                    name: 'mip-$band-$level',
                    program: mip,
                    workgroups: Workgroups(
                      (target + 7) ~/ 8,
                      (target + 7) ~/ 8,
                    ),
                    reads: [settings, output],
                    writes: [output],
                    bindings: ShaderBindings([
                      BufferBinding.uniform(0, settings),
                      BufferBinding.storageReadWrite(1, output),
                    ]),
                  ),
                );
                from = to;
                to += target * target * 3;
                n = target;
              }
            }
            final graph = await work.graphs.compile(
              GraphDescription(
                label: 'ocean-visual-pack',
                inputs: inputs.toList(),
                passes: passes,
              ),
            );
            await graph.execute();
            check();
          } finally {
            await work.close();
          }
        }
      } finally {
        await compiler.close();
      }
      check();
      return OceanWaveRenderData._(scope, state, size, first.seconds, buffers, {
        for (final entry in input.entries)
          entry.key: List.unmodifiable([
            for (final band in entry.value.bands) band.unresolvedSlopeVariance,
          ]),
      }, bytes);
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  /// Explicit qualification readback; not used by rendering or physical queries.
  Future<Float32List> debugRead(
    int chart, {
    int band = 0,
    int level = 0,
  }) async {
    RangeError.checkValidIndex(band, state.bands);
    RangeError.checkValueInInterval(level, 0, levels - 1);
    final buffer = buffers[chart];
    if (buffer == null) throw ArgumentError('Chart is not resident.');
    var offset = band * texelsPerBand, n = resolution;
    for (var i = 0; i < level; i++) {
      offset += n * n;
      n ~/= 2;
    }
    final bytes = await _scope.resources.readBuffer(
      buffer,
      offset: offset * 48,
      length: n * n * 48,
    );
    final view = ByteData.sublistView(bytes);
    return Float32List.fromList([
      for (var i = 0; i < bytes.length; i += 4)
        view.getFloat32(i, Endian.little),
    ]);
  }

  Future<void> close() => _scope.close();
}

const _copy = '''
@group(0) @binding(0) var<uniform> config:vec4<u32>;
@group(0) @binding(1) var<storage,read_write> output:array<vec4<f32>>;
@group(0) @binding(2) var displacement:texture_2d<f32>;
@group(0) @binding(3) var derivatives:texture_2d<f32>;
@group(0) @binding(4) var velocity:texture_2d<f32>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
  if (id.x>=config.x || id.y>=config.x) { return; }
  let p=vec2<i32>(id.xy); let at=config.z+3u*(id.y*config.x+id.x);
  let d=textureLoad(derivatives,p,0);
  output[at]=textureLoad(displacement,p,0); output[at+1u]=d;
  output[at+2u]=vec4(textureLoad(velocity,p,0).w,dot(d.xy,d.xy),0.,0.);
}
''';
const _mip = '''
@group(0) @binding(0) var<uniform> config:vec4<u32>;
@group(0) @binding(1) var<storage,read_write> output:array<vec4<f32>>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
  let n=config.x/2u; if (id.x>=n || id.y>=n) { return; }
  let p=2u*id.xy; let sourceBase=config.y+3u*(p.y*config.x+p.x);
  let dest=config.z+3u*(id.y*n+id.x);
  for (var c=0u;c<3u;c++) {
    output[dest+c]=.25*(output[sourceBase+c]+output[sourceBase+3u+c]+
      output[sourceBase+3u*config.x+c]+output[sourceBase+3u*config.x+3u+c]);
  }
}
''';
