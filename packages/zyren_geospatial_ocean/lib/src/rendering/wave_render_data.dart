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
/// levels. Each logical cell spans three RGBA32F texels: displacement/Jacobian, derivatives,
/// and (cross derivative, mean squared height slope, 0, 0). Velocity remains in
/// the independent simulation/query fields. Linear indexing fits the complete mip
/// chain into a 4N by N*bands atlas without six storage-buffer bindings. Temporary
/// compute buffers retire before publication. No production readback is required.
final class OceanWaveRenderData {
  final GpuScope _scope;
  final OceanSeaState state;
  final int resolution, levels, texelsPerBand, logicalPayloadBytes;
  final double seconds;
  final Map<int, GpuResource<Texture>> textures;
  final Map<int, List<double>> unresolvedSlopeVariance;
  bool get isClosed => _scope.isClosed;
  OceanWaveRenderData._(
    this._scope,
    this.state,
    this.resolution,
    this.seconds,
    Map<int, GpuResource<Texture>> textures,
    Map<int, List<double>> variance,
    this.logicalPayloadBytes,
  ) : textures = Map.unmodifiable(textures),
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
    mipTexels(resolution);
    return resolution * resolution * bands * charts * 64;
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
    final temporaryBufferBytes = mipTexels(size) * state.bands.length * 48;
    final transient =
        temporaryBufferBytes + (size.bitLength * state.bands.length + 1) * 16;
    if (bytes + transient + retainedBytes > maxLogicalBytes ||
        perChart > 64 * 1024 * 1024) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Packed visual waves exceed the total or per-texture allowance.',
      );
    }
    void check() {
      cancellation?.throwIfCancelled();
      if (parent.isClosed) throw StateError('Visual wave owner closed.');
      for (final entry in input.entries) {
        final source = entry.value;
        if (!source.isCurrent) throw StateError('Visual wave source is stale.');
        if (!source.seconds.isFinite ||
            source.seconds.abs() > 1e12 ||
            source.resolution != size ||
            source.seconds != first.seconds ||
            source.seaStateRevision !=
                oceanChartSeaState(state, entry.key).revision ||
            source.bands.length != state.bands.length) {
          throw ArgumentError(
            'Visual wave charts do not match their physical state/time.',
          );
        }
        for (var index = 0; index < source.bands.length; index++) {
          final band = source.bands[index];
          if (band.patchMetres != state.bands[index].patchMetres ||
              !band.unresolvedSlopeVariance.isFinite ||
              band.unresolvedSlopeVariance < 0) {
            throw ArgumentError('Invalid visual wave band metadata.');
          }
          for (final texture in [
            band.displacement,
            band.derivatives,
            band.velocity,
          ]) {
            final d = texture.descriptor as TextureDescriptor;
            if (texture.isClosed ||
                d.width != size ||
                d.height != size ||
                d.dimension != TextureDimension.d2 ||
                d.format != TextureFormat.rgba32Float ||
                !d.usage.contains(TextureUsage.sampled)) {
              throw ArgumentError('Invalid visual wave source texture.');
            }
          }
        }
      }
    }

    check();
    final scope = parent.createChild(label: 'ocean-visual-waves');
    final textures = <int, GpuResource<Texture>>{};
    try {
      final compiler = scope.createChild(label: 'ocean-visual-pack-work');
      try {
        final copy = await compiler.shaders.compile(ShaderSource.wgsl(_copy));
        final mip = await compiler.shaders.compile(ShaderSource.wgsl(_mip));
        final store = await compiler.shaders.compile(ShaderSource.wgsl(_store));
        for (final entry in input.entries) {
          check();
          final atlas = await scope.resources.createTexture(
            TextureDescriptor(
              label: 'ocean-visual-chart-${entry.key}',
              width: size * 4,
              height: size * state.bands.length,
              format: TextureFormat.rgba32Float,
              usage: {
                TextureUsage.storage,
                TextureUsage.sampled,
                TextureUsage.copySource,
              },
            ),
          );
          textures[entry.key] = atlas;
          final work = compiler.createChild(label: 'ocean-pack-chart');
          try {
            final output = await work.resources.createBuffer(
              BufferDescriptor(
                size: temporaryBufferBytes,
                usage: {BufferUsage.storage},
              ),
            );
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
            final storeSettings = await config(
              size * 4,
              temporaryBufferBytes ~/ 16,
              size * state.bands.length,
            );
            passes.add(
              ComputePassDescriptor(
                name: 'store-packed-texture',
                program: store,
                workgroups: Workgroups(
                  (size * 4 + 7) ~/ 8,
                  (size * state.bands.length + 7) ~/ 8,
                ),
                reads: [storeSettings, output],
                writes: [atlas],
                bindings: ShaderBindings([
                  BufferBinding.uniform(0, storeSettings),
                  BufferBinding.storageRead(1, output),
                  TextureBinding.storage(2, atlas),
                ]),
              ),
            );
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
      return OceanWaveRenderData._(
        scope,
        state,
        size,
        first.seconds,
        textures,
        {
          for (final entry in input.entries)
            entry.key: List.unmodifiable([
              for (final band in entry.value.bands)
                band.unresolvedSlopeVariance,
            ]),
        },
        bytes,
      );
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
    final texture = textures[chart];
    if (texture == null) throw ArgumentError('Chart is not resident.');
    var offset = band * texelsPerBand, n = resolution;
    for (var i = 0; i < level; i++) {
      offset += n * n;
      n ~/= 2;
    }
    final bytes = await _scope.resources.readTexture(texture);
    final view = ByteData.sublistView(bytes);
    return Float32List.fromList([
      for (var i = offset * 48; i < (offset + n * n) * 48; i += 4)
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

const _store = '''
@group(0) @binding(0) var<uniform> config:vec4<u32>;
@group(0) @binding(1) var<storage,read> source:array<vec4<f32>>;
@group(0) @binding(2) var atlas:texture_storage_2d<rgba32float,write>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
  if(id.x>=config.x || id.y>=config.z){return;}
  let at=id.y*config.x+id.x;var value=vec4(0.);
  if(at<config.y){value=source[at];}
  textureStore(atlas,vec2<i32>(id.xy),value);
}
''';
