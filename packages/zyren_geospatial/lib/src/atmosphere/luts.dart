import 'package:zyren/zyren.dart';
import 'parameters.dart';
import 'quality.dart';
import 'bruneton_wgsl.dart';
import 'precompute_wgsl.dart';
import 'runtime_wgsl.dart';
import 'specialize_textures.dart';

/// Complete immutable RGB lookup set. All outputs use linear RGBA32 float.
/// The supplied scopes own the result and precomputation workspace. Publish the
/// set only after generation succeeds, and close candidate scopes after failure.
final class AtmosphereLuts {
  final AtmosphereParameters parameters;
  final AtmosphereQuality quality;
  final Map<String, GpuResource<Texture>> textures;
  AtmosphereLuts._(
    this.parameters,
    this.quality,
    Map<String, GpuResource<Texture>> textures,
  ) : textures = Map.unmodifiable(textures);
  GpuResource<Texture> get transmittance => textures['transmittance']!;
  GpuResource<Texture> get rayleigh => textures['rayleigh']!;
  GpuResource<Texture> get mie => textures['mie']!;
  GpuResource<Texture> get higher => textures['higher']!;
  GpuResource<Texture> get irradiance => textures['irradiance']!;
  bool get isClosed => textures.values.any((t) => t.isClosed);

  /// Shader functions use kilometre positions and linear relative luminance.
  /// Bind these readonly tables and append [AtmosphereShader.source] to a WGSL
  /// module. The library supplies atmosphereSky, atmosphereSegment and direct /
  /// indirect irradiance functions. Keep this LUT lease alive while using it.
  AtmosphereShader shader({int group = 1, int firstBinding = 0}) {
    if (isClosed) throw StateError('Atmosphere LUT owner has closed.');
    if (group < 0 || group > 3 || firstBinding < 0 || firstBinding > 27) {
      throw ArgumentError('Invalid atmosphere shader binding range.');
    }
    final entries = {
      'atmosphereTransmittance': transmittance,
      'atmosphereRayleigh': rayleigh,
      'atmosphereMie': mie,
      'atmosphereHigher': higher,
      'atmosphereIrradiance': irradiance,
    };
    final source = StringBuffer(
      atmosphereDefinitions(parameters, quality) + atmosphereCommonWgsl,
    );
    final bindings = <ShaderBinding>[];
    var index = firstBinding;
    for (final entry in entries.entries) {
      final dimension =
          (entry.value.descriptor as TextureDescriptor).dimension ==
              TextureDimension.d3
          ? '3d'
          : '2d';
      source.writeln(
        '@group($group) @binding($index) var ${entry.key}: texture_$dimension<f32>;',
      );
      bindings.add(TextureBinding.sampled(index++, entry.value, group: group));
    }
    source.write(atmosphereRuntimeWgsl);
    return AtmosphereShader._(
      specializeAtmosphereTextures(source.toString()),
      ShaderBindings(bindings),
    );
  }

  static Future<AtmosphereLuts> generate({
    required ResourceScope resources,
    ResourceScope? workspace,
    required ShaderCompiler shaders,
    required GraphCompiler graphs,
    required AtmosphereParameters parameters,
    AtmosphereQuality quality = AtmosphereQuality.balanced,
    bool Function()? isCancelled,
  }) async {
    void check() {
      if (isCancelled?.call() ?? false) {
        throw StateError('Atmosphere generation cancelled.');
      }
    }

    check();
    final q = quality;
    Future<GpuResource<Texture>> texture(
      String label,
      int width,
      int height, {
      int depth = 1,
      bool temporary = false,
    }) async {
      check();
      return (temporary ? workspace ?? resources : resources).createTexture(
        TextureDescriptor(
          label: 'atmosphere $label',
          width: width,
          height: height,
          depth: depth,
          dimension: depth == 1 ? TextureDimension.d2 : TextureDimension.d3,
          format: TextureFormat.rgba32Float,
          usage: {
            TextureUsage.sampled,
            TextureUsage.storage,
            TextureUsage.copySource,
          },
        ),
      );
    }

    Future<GpuResource<Texture>> volume(
      String label, {
      bool temporary = false,
    }) => texture(
      label,
      q.scatteringWidth,
      q.viewSize,
      depth: q.radiusSize,
      temporary: temporary,
    );
    final t = await texture(
      'transmittance',
      q.transmittanceWidth,
      q.transmittanceHeight,
    );
    final ray = await volume('single Rayleigh'),
        mi = await volume('single Mie');
    final higherA = await volume('higher A', temporary: true),
        higherB = await volume('higher B');
    final density = await volume('density', temporary: true),
        multiple = await volume('delta multiple', temporary: true);
    final deltaI = await texture(
      'delta irradiance',
      q.irradianceWidth,
      q.irradianceHeight,
      temporary: true,
    );
    var irrIn = await texture(
      'irradiance A',
      q.irradianceWidth,
      q.irradianceHeight,
      temporary: true,
    );
    var irrOut = await texture(
      'irradiance B',
      q.irradianceWidth,
      q.irradianceHeight,
    );
    var higherIn = higherA, higherOut = higherB;
    final definitions =
        atmosphereDefinitions(parameters, q) + atmosphereCommonWgsl;
    // Execute each dependency stage separately. Cancellation can retire a
    // candidate between submissions without publishing an incomplete LUT set.
    Future<void> pass(
      String name,
      Map<String, GpuResource<Texture>> reads,
      Map<String, GpuResource<Texture>> writes,
      String body, {
      String functions = '',
      int order = 0,
    }) async {
      check();
      final bindings = <ShaderBinding>[];
      final declarations = StringBuffer();
      var binding = 0;
      for (final (map, write) in [(reads, false), (writes, true)]) {
        for (final e in map.entries) {
          final d = e.value.descriptor as TextureDescriptor;
          final dim = d.dimension == TextureDimension.d3 ? '3d' : '2d';
          declarations.writeln(
            '@group(0) @binding($binding) var ${e.key}: ${write ? 'texture_storage_$dim<rgba32float,write>' : 'texture_$dim<f32>'};',
          );
          bindings.add(
            write
                ? TextureBinding.storage(binding, e.value)
                : TextureBinding.sampled(binding, e.value),
          );
          binding++;
        }
      }
      final d = writes.values.first.descriptor as TextureDescriptor;
      final bound = d.dimension == TextureDimension.d3 ? 'id' : 'id.xy';
      final code =
          '$definitions\nconst ORDER: i32 = $order;\n$declarations\n$functions\n'
          '@compute @workgroup_size(4,4,1) fn main(@builtin(global_invocation_id) id:vec3<u32>){'
          'if(any($bound>=textureDimensions(${writes.keys.first}))){return;}\n$body\n}';
      final program = await shaders.compile(
        ShaderSource.wgsl(
          specializeAtmosphereTextures(code),
          label: 'atmosphere $name',
        ),
      );
      check();
      final graph = await graphs.compile(
        GraphDescription(
          label: 'atmosphere $name',
          inputs: reads.values,
          passes: [
            ComputePassDescriptor(
              name: name,
              program: program,
              bindings: ShaderBindings(bindings),
              reads: reads.values,
              writes: writes.values,
              workgroups: Workgroups(
                (d.width + 3) ~/ 4,
                (d.height + 3) ~/ 4,
                d.depth,
              ),
            ),
          ],
        ),
      );
      await graph.execute();
      check();
    }

    await pass('transmittance', {}, {'output': t}, transmittanceWgsl);
    await pass(
      'direct irradiance',
      {'transmittance': t},
      {'output': deltaI},
      directIrradianceWgsl,
    );
    await pass(
      'single scattering',
      {'transmittance': t},
      {'rayleigh': ray, 'mie': mi},
      singleScatteringWgsl,
    );
    await pass(
      'clear higher',
      {},
      {'a': higherA, 'b': higherB, 'c': multiple},
      'textureStore(a,vec3<i32>(id),vec4<f32>(0.));textureStore(b,vec3<i32>(id),vec4<f32>(0.));textureStore(c,vec3<i32>(id),vec4<f32>(0.));',
    );
    await pass(
      'clear irradiance',
      {},
      {'a': irrIn, 'b': irrOut},
      'textureStore(a,vec2<i32>(id.xy),vec4<f32>(0.));textureStore(b,vec2<i32>(id.xy),vec4<f32>(0.));',
    );
    for (var order = 2; order <= 4; order++) {
      // The first indirect order reads single scattering. Later orders read
      // the previous multiple-scattering delta, before the line integral writes it.
      final incoming = order == 2
          ? {'rayleigh': ray, 'mie': mi}
          : {'multiple': multiple};
      final incident = order == 2
          ? incidentWgsl.replaceAll(
              ' return scattering(multiple,r,mu,mus,nu,ground);',
              ' return vec3<f32>(0.);',
            )
          : 'fn incident(r:f32,mu:f32,mus:f32,nu:f32,ground:bool)->vec3<f32>{return scattering(multiple,r,mu,mus,nu,ground);}';
      await pass(
        'density $order',
        {'transmittance': t, ...incoming, 'deltaIrradiance': deltaI},
        {'output': density},
        scatteringDensityWgsl,
        functions: incident,
        order: order,
      );
      await pass(
        'indirect irradiance $order',
        {...incoming, 'previous': irrIn},
        {'deltaIrradiance': deltaI, 'output': irrOut},
        indirectIrradianceWgsl,
        functions: incident,
        order: order,
      );
      await pass(
        'multiple scattering $order',
        {'transmittance': t, 'density': density, 'previous': higherIn},
        {'multiple': multiple, 'output': higherOut},
        multipleScatteringWgsl,
      );
      (irrIn, irrOut) = (irrOut, irrIn);
      (higherIn, higherOut) = (higherOut, higherIn);
    }
    return AtmosphereLuts._(parameters, q, {
      'transmittance': t,
      'rayleigh': ray,
      'mie': mi,
      'higher': higherIn,
      'irradiance': irrIn,
    });
  }
}

/// A complete WGSL library and its readonly texture slots.
final class AtmosphereShader {
  final String source;
  final ShaderBindings bindings;
  AtmosphereShader._(this.source, this.bindings);
}
