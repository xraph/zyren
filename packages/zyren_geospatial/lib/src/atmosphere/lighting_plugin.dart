import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../astronomy/celestial_directions.dart';
import 'lighting_sampler.dart';
import 'lut_cache.dart';
import 'luts.dart';
import 'plugin.dart';

const atmosphereLighting = ServiceKey<AtmosphereLightingController>(
  'geospatial.atmosphereLighting',
);

/// Native scene lights and optional sky reflections following the atmosphere.
/// The sky probe defaults off when the environment supplies diffuse irradiance.
final class AtmosphereLightingPlugin extends ScenePlugin {
  final bool sun, skyProbe, environment, environmentGround;
  final double sunIntensity, skyIntensity, distanceThreshold, angularThreshold;
  final int captureResolution,
      environmentResolution,
      roughnessLevels,
      samples,
      brdfSize;
  final ShadowSettings? shadow;
  AtmosphereLightingController? _controller;
  AtmosphereLightingController get controller =>
      _controller ?? (throw StateError('Atmosphere lighting is not attached.'));
  AtmosphereLightingPlugin({
    this.sun = true,
    bool? skyProbe,
    this.environment = false,
    this.environmentGround = true,
    this.sunIntensity = 1,
    this.skyIntensity = 1,
    this.distanceThreshold = 1000,
    this.angularThreshold = math.pi / 1800,
    this.captureResolution = 64,
    this.environmentResolution = 32,
    this.roughnessLevels = 8,
    this.samples = 128,
    this.brdfSize = 32,
    this.shadow,
  }) : skyProbe = skyProbe ?? !environment {
    if (!sunIntensity.isFinite ||
        sunIntensity < 0 ||
        sunIntensity > 65504 ||
        !skyIntensity.isFinite ||
        skyIntensity < 0 ||
        skyIntensity > 65504 ||
        !distanceThreshold.isFinite ||
        distanceThreshold <= 0 ||
        distanceThreshold > 1e7 ||
        !angularThreshold.isFinite ||
        angularThreshold <= 0 ||
        angularThreshold > math.pi ||
        captureResolution < 4 ||
        captureResolution > 256 ||
        environmentResolution < 4 ||
        environmentResolution > 128 ||
        roughnessLevels < 2 ||
        roughnessLevels > 16 ||
        samples < 32 ||
        samples > 1024 ||
        brdfSize < 8 ||
        brdfSize > 128 ||
        (environmentResolution *
                        environmentResolution *
                        2 *
                        (roughnessLevels + 1) +
                    brdfSize * brdfSize) *
                samples >
            64000000) {
      throw ArgumentError('Invalid atmosphere lighting or convolution limits.');
    }
  }
  @override
  String get id => 'atmosphere-lighting';
  @override
  Set<String> get dependencies => {'atmosphere'};
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.punctualLights,
    if (environment) ...{
      RenderFeature.environmentLighting,
      RenderFeature.compute,
      RenderFeature.renderGraphs,
      RenderFeature.floatTextures,
      RenderFeature.volumeTextures,
    },
  };
  @override
  Future<void> attach(PluginContext context) async {
    final control = _controller = AtmosphereLightingController._(
      this,
      context,
      context.createGpuScope(label: 'atmosphere lighting'),
      context.service(atmosphere),
    );
    context.scope.onClose(control._close);
    context.provide(atmosphereLighting, control);
    await control._update();
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) =>
      controller._update();
}

/// Adjust intensity through this controller and shadows through the owned sun
/// light. Colors, directions and physical intensities follow the atmosphere.
final class AtmosphereLightingController {
  final AtmosphereLightingPlugin _plugin;
  final PluginContext _context;
  final GpuScope _owner;
  final AtmosphereController _atmosphere;
  late final DirectionalLight? sunLight = _plugin.sun
      ? DirectionalLight(
          intensity: _plugin.sunIntensity,
          shadow: _plugin.shadow,
          name: 'Atmosphere sun',
        )
      : null;
  late final HemisphereLight? skyProbe = _plugin.skyProbe
      ? HemisphereLight(
          intensity: _plugin.skyIntensity,
          name: 'Atmosphere sky probe',
        )
      : null;
  AtmosphereLutLease? _lease;
  AtmosphereLightingSampler? _sampler;
  AtmosphereLightSample? _sample;
  _SkyEnvironment? _environment;
  EnvironmentRegistration? _registration;
  (int, int, int)? _cell;
  Vec3? _sun;
  bool _closed = false, _addedLights = false;
  Future<void> _queue = Future.value();
  int _tableReadbacks = 0, _environmentGeneration = 0;
  late double _sunIntensity = _plugin.sunIntensity,
      _skyIntensity = _plugin.skyIntensity;
  double get sunIntensity => _sunIntensity;
  set sunIntensity(double value) {
    _checkIntensity(value);
    _sunIntensity = value;
    _context.invalidate();
  }

  double get skyIntensity => _skyIntensity;
  set skyIntensity(double value) {
    _checkIntensity(value);
    _skyIntensity = value;
    _context.invalidate();
  }

  void _checkIntensity(double value) {
    if (isClosed) throw StateError('Atmosphere lighting has closed.');
    if (!value.isFinite || value < 0 || value > 65504) {
      throw ArgumentError.value(value, 'intensity');
    }
  }

  AtmosphereLightingController._(
    this._plugin,
    this._context,
    this._owner,
    this._atmosphere,
  );
  bool get isClosed => _closed || _owner.isClosed;
  AtmosphereLightSample? get sample => _sample;
  int get tableReadbacks => _tableReadbacks;
  int get environmentGeneration => _environmentGeneration;
  Future<void> _update() {
    final next = _queue.then((_) => _prepare());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _prepare() async {
    if (isClosed) throw StateError('Atmosphere lighting has closed.');
    final lease = await _atmosphere.acquireLighting(
      isCancelled: () => isClosed,
    );
    _SkyEnvironment? candidate;
    var adopted = false;
    try {
      final changed = !identical(lease.luts, _lease?.luts);
      final sampler = changed
          ? await AtmosphereLightingSampler.read(
              luts: lease.luts,
              owner: _owner,
              onReadback: () => _tableReadbacks++,
            )
          : _sampler!;
      final transform = _atmosphere.worldToEcef;
      final inverse = transform.inverted();
      final ecef = _point(transform, _context.camera.position);
      final sun = CelestialDirections.at(
        _atmosphere.date,
        observerECEF: ecef,
      ).sunECEF;
      final value = sampler.sample(
        positionECEF: ecef,
        sunDirectionECEF: sun,
        ellipsoid: _atmosphere.ellipsoid,
        correctAltitude: _atmosphere.correctAltitude,
      );
      final directColor = _lightColor(value.sunIrradiance);
      final probeColor = _lightColor(value.skyIrradiance);
      final directIntensity = _scaledIntensity(directColor.$2, _sunIntensity);
      final probeIntensity = _scaledIntensity(probeColor.$2, _skyIntensity);
      final size = _plugin.distanceThreshold;
      final cell = (
        (ecef.x / size).round(),
        (ecef.y / size).round(),
        (ecef.z / size).round(),
      );
      final angle = _sun == null
          ? double.infinity
          : math.acos(_sun!.dot(sun).clamp(-1.0, 1.0));
      if (_plugin.environment &&
          (changed ||
              _environment == null ||
              cell != _cell ||
              angle > _plugin.angularThreshold)) {
        var corrected = ecef;
        if (_atmosphere.correctAltitude) {
          final surface = _atmosphere.ellipsoid.projectOnSurface(ecef);
          corrected =
              ecef -
              surface +
              _atmosphere.ellipsoid.surfaceNormal(surface) *
                  lease.luts.parameters.bottomRadius;
        }
        candidate = await _SkyEnvironment.build(
          _owner,
          lease.luts,
          _plugin,
          corrected,
          sun,
          transform,
        );
      }
      if (isClosed) throw StateError('Atmosphere lighting has closed.');
      final mapOwner = candidate ?? _environment;
      if (mapOwner != null && mapOwner.map.intensity != _skyIntensity) {
        final old = mapOwner.map;
        mapOwner.map = EnvironmentMap(
          irradiance: old.irradiance,
          specular: old.specular,
          brdf: old.brdf,
          intensity: _skyIntensity,
        );
        if (candidate == null) _registration!.replace(mapOwner.map);
      }
      if (candidate != null) {
        if (_registration == null) {
          _registration = _context.scene.addEnvironment(candidate.map);
        } else {
          _registration!.replace(candidate.map);
        }
      }
      final previousEnvironment = _environment, previousLease = _lease;
      _lease = lease;
      _sampler = sampler;
      _sample = value;
      adopted = true;
      if (candidate != null) {
        _environment = candidate;
        _environmentGeneration++;
        _cell = cell;
        _sun = sun;
      }
      final direct = sunLight, probe = skyProbe;
      if (direct != null) {
        direct.direction = -_direction(inverse, sun);
        direct.color = directColor.$1;
        direct.intensity = directIntensity;
      }
      if (probe != null) {
        probe.direction = _direction(inverse, value.upECEF);
        probe.color = probeColor.$1;
        probe.intensity = probeIntensity;
      }
      if (!_addedLights) {
        if (direct != null) _context.scene.add(direct);
        if (probe != null) _context.scene.add(probe);
        _addedLights = true;
      }
      try {
        if (candidate != null) await previousEnvironment?.scope.close();
      } finally {
        await previousLease?.close();
      }
    } finally {
      if (!adopted) {
        try {
          await candidate?.scope.close();
        } finally {
          await lease.close();
        }
      }
    }
  }

  Future<void> _close() async {
    _closed = true;
    await _queue;
    if (_addedLights) {
      if (sunLight case final light?) _context.scene.remove(light);
      if (skyProbe case final light?) _context.scene.remove(light);
    }
    _registration?.dispose();
    try {
      await _environment?.scope.close();
    } finally {
      try {
        await _lease?.close();
      } finally {
        await _owner.close();
      }
    }
  }
}

Vec3 _point(Mat4 matrix, Vec3 p) {
  final m = matrix.storage;
  return _direction(matrix, p) + Vec3(m[12], m[13], m[14]);
}

Vec3 _direction(Mat4 matrix, Vec3 p) {
  final m = matrix.storage;
  return Vec3(
    m[0] * p.x + m[4] * p.y + m[8] * p.z,
    m[1] * p.x + m[5] * p.y + m[9] * p.z,
    m[2] * p.x + m[6] * p.y + m[10] * p.z,
  );
}

double _scaledIntensity(double irradiance, double scale) {
  final value = irradiance * scale;
  if (!value.isFinite || value < 0 || value > 1e12) {
    throw ArgumentError(
      'Atmosphere irradiance exceeds the native light intensity range.',
    );
  }
  return value;
}

(Color3, double) _lightColor(Vec3 value) {
  final peak = math.max(value.x, math.max(value.y, value.z));
  return peak == 0
      ? (const Color3(0, 0, 0), 0)
      : (Color3(value.x / peak, value.y / peak, value.z / peak), peak);
}

final class _SkyEnvironment {
  final GpuScope scope;
  EnvironmentMap map;
  _SkyEnvironment(this.scope, this.map);
  static Future<_SkyEnvironment> build(
    GpuScope owner,
    AtmosphereLuts luts,
    AtmosphereLightingPlugin settings,
    Vec3 origin,
    Vec3 sun,
    Mat4 worldToEcef,
  ) async {
    final scope = owner.createChild(label: 'atmosphere environment');
    final workspace = scope.createChild(label: 'sky capture workspace');
    try {
      final size = settings.captureResolution;
      final image = await workspace.resources.createTexture(
        TextureDescriptor(
          label: 'sky radiance',
          width: size * 2,
          height: size,
          format: TextureFormat.rgba16Float,
          usage: {TextureUsage.storage, TextureUsage.sampled},
        ),
      );
      final uniform = await workspace.resources.createBuffer(
        BufferDescriptor(
          size: 96,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      await workspace.resources.writeBuffer(
        uniform,
        Float32List.fromList([
          ...(origin * .001).storage,
          settings.environmentGround ? 1 : 0,
          ...sun.storage,
          0,
          ...worldToEcef.storage.take(12),
          0,
          0,
          0,
          1,
        ]),
      );
      final library = luts.shader();
      final program = await workspace.shaders.compile(
        ShaderSource.wgsl('''
${library.source}
struct SkyFrame { origin:vec4<f32>,sun:vec4<f32>,worldToEcef:mat4x4<f32> }
@group(0) @binding(0) var<uniform> frame:SkyFrame;
@group(0) @binding(1) var output:texture_storage_2d<rgba16float,write>;
@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let size=textureDimensions(output);if(any(id.xy>=size)){return;}
 let uv=(vec2<f32>(id.xy)+.5)/vec2<f32>(size);let phi=(uv.x-.5)*2.*PI;let theta=uv.y*PI;
 let world=vec3<f32>(cos(phi)*sin(theta),cos(theta),sin(phi)*sin(theta));
 let ray=normalize((frame.worldToEcef*vec4<f32>(world,0.)).xyz);
 let sky=atmosphereSky(frame.origin.xyz,ray,frame.sun.xyz,frame.origin.w>0.);
 textureStore(output,vec2<i32>(id.xy),vec4<f32>(clamp(sky.radiance,vec3<f32>(0.),vec3<f32>(65504.)),1.));
}
'''),
      );
      final graph = await workspace.graphs.compile(
        GraphDescription(
          inputs: [...luts.textures.values, uniform],
          passes: [
            ComputePassDescriptor(
              name: 'sky environment capture',
              program: program,
              bindings: ShaderBindings([
                ...library.bindings.entries,
                BufferBinding.uniform(0, uniform),
                TextureBinding.storage(1, image),
              ]),
              reads: [...luts.textures.values, uniform],
              writes: [image],
              workgroups: Workgroups((size * 2 + 7) ~/ 8, (size + 7) ~/ 8),
            ),
          ],
        ),
      );
      await graph.execute();
      final output = await EnvironmentMap.generate(
        resources: scope.resources,
        shaders: workspace.shaders,
        graphs: workspace.graphs,
        source: image,
        resolution: settings.environmentResolution,
        roughnessLevels: settings.roughnessLevels,
        samples: settings.samples,
        brdfSize: settings.brdfSize,
      );
      await workspace.close();
      return _SkyEnvironment(
        scope,
        EnvironmentMap(
          irradiance: output.irradiance,
          specular: output.specular,
          brdf: output.brdf,
          intensity: settings.skyIntensity,
        ),
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}
