import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../surface/cube_patch.dart';
import '../surface/geometry.dart';
import '../surface/wave_chart.dart';
import 'lighting.dart';
import 'optics.dart';
import 'reflections.dart';
import 'wave_render_data.dart';
import 'water_wgsl.dart';
import 'water_geometry.dart';
import 'programs.dart';
import '../interactions/field.dart';

enum OceanWaterDebug { color, normal, waterPath, reflectionConfidence, foam }

/// Native water for an ECEF-oriented local patch. Positions are local to
/// originEcef; lengths and mesh scale stay in metres. The scene may apply a rigid
/// world-frame transform, but scaling changes optical distances and is unsupported.
/// Retains wave resources and lighting until close. Live wave inputs must be
/// ready before rendering; their updates change this material in place.
final class OceanWaterMaterial {
  final GpuScope _scope;
  final bool _deformed;
  final GpuResource<Buffer> _uniform;
  bool _foamEnabled = true;
  bool get foamEnabled => _foamEnabled;

  /// Changes only shading. Interaction fields and physical samples keep running.
  /// Await this update before submitting a frame with this material.
  Future<void> setFoamEnabled(bool enabled) async {
    if (isClosed) throw StateError('Water material closed.');
    if (_foamEnabled == enabled) return;
    await _scope.resources.writeBuffer(
      _uniform,
      Float32List.fromList([enabled ? 1 : 0]),
      offset: 51 * 4,
    );
    _foamEnabled = enabled;
  }

  final OceanInteractionField? interactions;
  final List<ShaderBinding> _interactionBindings;
  final OceanWaveRenderInputs _waves;
  final OceanWaterPrograms? _programs;
  int _waveRevision = -1, _interactionRevision = -1, _surfaceRevision = 0;
  int get surfaceRevision {
    final wave = _waves.revision, interaction = interactions?.revision ?? 0;
    if (wave != _waveRevision || interaction != _interactionRevision) {
      _waveRevision = wave;
      _interactionRevision = interaction;
      _surfaceRevision++;
    }
    return _surfaceRevision;
  }

  bool get isReady =>
      !isClosed &&
      (!_waves.changesOverTime || _waves.isReady) &&
      (interactions?.isReady ?? true);
  final String _source;
  final List<ShaderBinding> _waveBindings;
  final OceanWaterPatchControls? controls;
  final TextureBinding _controlBinding;
  final OceanPatchId patch;
  final Vec3 originEcef;
  final Ellipsoid ellipsoid;
  final OceanOptics optics;
  final OceanLighting lighting;
  final OceanReflectionSettings reflections;
  final ShaderMaterial material;
  double get seconds => _waves.seconds;
  final double meanLevelMetres;
  final String seaStateRevision;
  final int ownLogicalBytes;
  bool get isClosed => _scope.isClosed;
  OceanWaterMaterial._(
    this._scope,
    this._uniform,
    this._deformed,
    this.interactions,
    this._interactionBindings,
    this.patch,
    this.originEcef,
    this.ellipsoid,
    this.optics,
    this.lighting,
    this.reflections,
    this.material,
    this._waves,
    this._programs,
    this.meanLevelMetres,
    this.seaStateRevision,
    this.ownLogicalBytes,
    this._source,
    this._waveBindings,
    this.controls,
    this._controlBinding,
  );

  static Future<OceanWaterMaterial> create(
    GpuScope parent, {
    required OceanWaveRenderInputs waves,
    required OceanPatchId patch,
    Vec3? originEcef,
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
    required double geometrySpacingMetres,
    OceanOptics? optics,
    OceanLighting? lighting,
    OceanReflectionSettings? reflections,
    OceanWaterDebug debug = OceanWaterDebug.color,
    bool deformed = false,
    OceanWaterPatchControls? controls,
    OceanInteractionField? interactions,
    OceanWaterPrograms? programs,
  }) async {
    validateOceanEllipsoid(ellipsoid);
    final origin = originEcef ?? patch.point(.5, .5, ellipsoid);
    if (!waves.isReady) throw StateError('Water wave inputs are not ready.');
    if (interactions != null && !interactions.isReady) {
      throw StateError('Interaction field is not ready.');
    }
    if (!origin.isFinite ||
        !geometrySpacingMetres.isFinite ||
        geometrySpacingMetres <= 0 ||
        geometrySpacingMetres > 1e8) {
      throw ArgumentError('Invalid water patch origin or geometry spacing.');
    }
    if (controls != null &&
        (controls.geometry.id != patch || controls.geometry.origin != origin)) {
      throw ArgumentError(
        'Water controls do not match the material patch origin.',
      );
    }
    final useDeformation = controls?.morphing ?? deformed;
    final charts = OceanWaveCharts(
      ellipsoid: ellipsoid,
      seed: waves.state.seed,
    );
    if (controls != null &&
        (controls.ellipsoid.x != ellipsoid.x ||
            controls.ellipsoid.y != ellipsoid.y ||
            controls.ellipsoid.z != ellipsoid.z)) {
      throw ArgumentError(
        'Water controls and material must share an ellipsoid.',
      );
    }
    final required = {
      ...charts.chartsForPatch(patch),
      ...?controls?.requiredChartIds,
    };
    if (!waves.textures.keys.toSet().containsAll(required)) {
      throw ArgumentError('Water patch requires resident charts $required.');
    }
    final optical = optics ?? OceanOptics(),
        light = lighting ?? OceanLighting();
    final reflection = reflections ?? OceanReflectionSettings();
    final scope = parent.createChild(label: 'ocean-water-material');
    try {
      final uniform = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 1088,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final empty = await scope.resources.createTexture(
        TextureDescriptor(
          width: 1,
          height: 1,
          format: TextureFormat.rgba32Float,
          usage: {TextureUsage.sampled},
        ),
      );
      final bindings = <ShaderBinding>[
        BufferBinding.uniform(0, uniform, group: 1),
      ];
      for (var chart = 0; chart < 6; chart++) {
        final texture = waves.textures[chart];
        bindings.add(
          TextureBinding.sampled(
            chart + 1,
            texture == null ? empty : await scope.resources.retain(texture),
            group: 1,
          ),
        );
      }
      var controlTexture = empty;
      if (controls != null) {
        controlTexture = await scope.resources.createTexture(
          TextureDescriptor(
            width: controls.textureWidth,
            height: controls.textureHeight,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await scope.resources.writeTexture(
          controlTexture,
          controls.encode().buffer.asUint8List(),
        );
      }
      final controlBinding = TextureBinding.sampled(
        13,
        controlTexture,
        group: 1,
        visibility: {ShaderStage.vertex},
      );
      bindings.add(controlBinding);
      final data = Float32List(272);
      void vector(int slot, Vec3 v, [double w = 0]) =>
          data.setRange(slot * 4, slot * 4 + 4, [v.x, v.y, v.z, w]);
      final inverse =
          ellipsoid.reciprocalRadiiSquared * ellipsoid.maximumRadius;
      vector(
        0,
        Vec3(origin.x * inverse.x, origin.y * inverse.y, origin.z * inverse.z),
        waves.state.meanLevel,
      );
      vector(1, inverse);
      vector(2, origin / 1000);
      data.setRange(12, 16, [
        geometrySpacingMetres,
        optical.maximumPathMetres,
        optical.indexOfRefraction,
        optical.roughness,
      ]);
      data.setRange(16, 20, [
        waves.resolution.toDouble(),
        waves.levels.toDouble(),
        waves.bandCount.toDouble(),
        waves.atlasLayout == OceanWaveAtlasLayout.blend
            ? -1
            : waves.texelsPerBand.toDouble(),
      ]);
      vector(5, optical.absorptionPerMetre);
      vector(6, optical.scatteringPerMetre);
      vector(7, light.sunDirectionEcef.normalized());
      vector(8, light.sunIrradiance);
      vector(9, light.skyRadiance);
      vector(10, light.groundRadiance);
      data.setRange(44, 48, [
        reflection.mode.index.toDouble(),
        reflection.stepLimit.toDouble(),
        reflection.maximumDistanceMetres,
        reflection.thicknessMetres,
      ]);
      data.setRange(48, 52, [
        reflection.pixelBudget.toDouble(),
        reflection.confidenceFade,
        debug.index.toDouble(),
        1,
      ]);
      data.setRange(52, 56, [
        light.environment?.intensity ?? 1,
        light.environment?.rotation ?? 0,
        0,
        0,
      ]);
      data[54] = controls?.textureWidth.toDouble() ?? 1;
      data[55] = controls == null ? 0 : 1;
      for (final chart in waves.textures.keys) {
        data[56 + chart] = 1;
        final u = origin.dot(oceanCubeFaces[chart].u),
            v = origin.dot(oceanCubeFaces[chart].v);
        for (var band = 0; band < waves.bandCount; band++) {
          final length = waves.state.bands[band].patchMetres;
          final at = 64 + (chart * 8 + band) * 4;
          data.setRange(at, at + 4, [
            u % length,
            v % length,
            length,
            waves.unresolvedSlopeVariance[chart]![band],
          ]);
        }
      }
      if (interactions != null) {
        vector(64, origin - interactions.referenceAnchorEcef);
        vector(65, interactions.east);
        vector(66, interactions.north);
        vector(67, interactions.up);
      }
      if (data.any((v) => !v.isFinite)) {
        throw ArgumentError('Water uniforms exceeded native float range.');
      }
      await scope.resources.writeBuffer(uniform, data);
      var environmentSource = _hemisphere;
      if (light.atmosphere case final atmosphere?) {
        final library = atmosphere.shader(group: 1, firstBinding: 7);
        for (final b in library.bindings.entries) {
          if (b is TextureBinding) {
            bindings.add(
              TextureBinding.sampled(
                b.binding,
                await scope.resources.retain(b.resource),
                group: b.group,
                visibility: {ShaderStage.fragment},
              ),
            );
          } else if (b is SamplerBinding) {
            bindings.add(
              SamplerBinding(
                b.binding,
                sampler: b.sampler,
                group: b.group,
                visibility: {ShaderStage.fragment},
              ),
            );
          }
        }
        environmentSource = library.source + _atmosphere;
      } else if (light.environment case final environment?) {
        bindings.addAll([
          TextureBinding.sampled(
            7,
            await scope.resources.retain(environment.specular),
            group: 1,
            visibility: {ShaderStage.fragment},
          ),
          TextureBinding.sampled(
            8,
            await scope.resources.retain(environment.irradiance),
            group: 1,
            visibility: {ShaderStage.fragment},
          ),
          SamplerBinding(
            9,
            group: 1,
            visibility: {ShaderStage.fragment},
            sampler: const SamplerDescriptor(
              wrapU: TextureWrap.repeat,
              wrapV: TextureWrap.clampToEdge,
              minFilter: TextureFilter.linear,
              magFilter: TextureFilter.linear,
            ),
          ),
        ]);
        environmentSource = _environment;
      }
      final interactionBindings = <ShaderBinding>[];
      if (interactions != null) {
        interactionBindings.add(
          TextureBinding.sampled(
            15,
            await scope.resources.retain(interactions.texture),
            group: 1,
          ),
        );
        bindings.addAll(interactionBindings);
      }
      final source = oceanWaterWgsl(
        deformed: useDeformation,
        environmentSource: environmentSource,
        interactions: interactions != null,
      );
      final shader = ShaderSource.wgsl(source, label: 'ocean-water');
      final geometry = useDeformation
          ? MeshShaderGeometry.deformed
          : MeshShaderGeometry.rigid;
      final program = programs == null
          ? await scope.shaders.compileMesh(
              shader,
              bindings: ShaderBindings(bindings),
              sceneInputs: MeshSceneInputs.opaqueColorDepth,
              geometry: geometry,
            )
          : await programs.bind(
              scope,
              shader,
              bindings: ShaderBindings(bindings),
              sceneInputs: MeshSceneInputs.opaqueColorDepth,
              geometry: geometry,
            );
      if (parent.isClosed) {
        throw StateError('Water owner closed during preparation.');
      }
      return OceanWaterMaterial._(
        scope,
        uniform,
        useDeformation,
        interactions,
        List.unmodifiable(interactionBindings),
        patch,
        origin,
        ellipsoid,
        optical,
        light,
        reflection,
        ShaderMaterial(program, side: MaterialSide.doubleSided),
        waves,
        programs,
        waves.state.meanLevel,
        waves.state.revision,
        1104 + (controls?.logicalBytes ?? 0),
        source,
        List.unmodifiable(bindings.take(7)),
        controls,
        controlBinding,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  /// Retains the filtered visual wave field for a custom ocean pass. The WGSL
  /// supplies waterSurface(localEcef, footprintMetres) and group 1 bindings 0..6.
  /// The receiving scope owns the retained inputs, including on partial failure.
  /// This is a rendering contract, without physical query accuracy guarantees.
  Future<OceanWaveShaderInputs> retainWaveInputs(GpuScope owner) async {
    if (!isReady) throw StateError('Water material inputs are not ready.');
    final bindings = <ShaderBinding>[];
    for (final binding in _waveBindings) {
      if (binding is BufferBinding) {
        bindings.add(
          BufferBinding.uniform(
            binding.binding,
            await owner.resources.retain(binding.resource),
            group: 1,
          ),
        );
      } else if (binding is TextureBinding) {
        bindings.add(
          TextureBinding.sampled(
            binding.binding,
            await owner.resources.retain(binding.resource),
            group: 1,
          ),
        );
      }
    }
    return OceanWaveShaderInputs._(oceanWaveFieldWgsl, bindings);
  }

  /// Builds a scope-owned native boundary shader with the same displacement,
  /// stitch controls and deformation profile as this surface. The forward
  /// uniform contains the current world-space camera direction in XYZ.
  Future<ShaderMaterial> createBoundaryMaterial(
    GpuScope owner,
    GpuResource<Buffer> forward,
  ) async {
    if (!isReady) throw StateError('Water material inputs are not ready.');
    final bindings = <ShaderBinding>[];
    for (final binding in [
      ..._waveBindings,
      ..._interactionBindings,
      _controlBinding,
    ]) {
      if (binding is BufferBinding) {
        bindings.add(
          BufferBinding.uniform(
            binding.binding,
            await owner.resources.retain(binding.resource),
            group: 1,
          ),
        );
      } else if (binding is TextureBinding) {
        bindings.add(
          TextureBinding.sampled(
            binding.binding,
            await owner.resources.retain(binding.resource),
            group: 1,
          ),
        );
      }
    }
    bindings.add(BufferBinding.uniform(14, forward, group: 1));
    final shader = ShaderSource.wgsl(
      oceanWaterWgsl(
        deformed: _deformed,
        environmentSource: '',
        boundary: true,
        interactions: interactions != null,
      ),
      label: 'ocean-surface-boundary',
    );
    final geometry = _deformed
        ? MeshShaderGeometry.deformed
        : MeshShaderGeometry.rigid;
    final program = _programs == null
        ? await owner.shaders.compileMesh(
            shader,
            bindings: ShaderBindings(bindings),
            geometry: geometry,
          )
        : await _programs.bind(
            owner,
            shader,
            bindings: ShaderBindings(bindings),
            geometry: geometry,
          );
    return ShaderMaterial(program, side: MaterialSide.doubleSided);
  }

  Mesh createMesh(OceanPatchGeometry geometry) {
    if (!isReady) throw StateError('Water material inputs are not ready.');
    if (geometry.id != patch || geometry.origin != originEcef) {
      throw ArgumentError('Geometry and water material origins must match.');
    }
    if (controls != null &&
        !identical(geometry.geometry, controls!.geometry.geometry)) {
      throw ArgumentError('Use the geometry that supplied the water controls.');
    }
    return Mesh(geometry.geometry, material)..position = originEcef;
  }

  /// Explicit bounded native diagnostic. It evaluates the same filtered field
  /// used by this material, in local ECEF axes. It is not a physical query API.
  Future<List<OceanWaterSurfaceDebug>> debugSurface(
    List<Vec3> points, {
    double footprintMetres = 0,
  }) async {
    if (!isReady) throw StateError('Water material inputs are not ready.');
    final input = List<Vec3>.of(points);
    if (input.isEmpty ||
        input.length > 512 ||
        input.any((p) => !p.isFinite) ||
        !footprintMetres.isFinite ||
        footprintMetres < 0 ||
        footprintMetres > 1e8) {
      throw ArgumentError('Invalid water diagnostic sample batch.');
    }
    final work = _scope.createChild(label: 'water-surface-diagnostic');
    try {
      final locations = await work.resources.createBuffer(
        BufferDescriptor(
          size: input.length * 16,
          usage: {BufferUsage.storage, BufferUsage.copyDestination},
        ),
      );
      final output = await work.resources.createBuffer(
        BufferDescriptor(
          size: input.length * 32,
          usage: {BufferUsage.storage, BufferUsage.copySource},
        ),
      );
      await work.resources.writeBuffer(
        locations,
        Float32List.fromList([
          for (final p in input) ...[p.x, p.y, p.z, footprintMetres],
        ]),
      );
      final program = await work.shaders.compile(
        ShaderSource.wgsl('''
$_source
@group(0) @binding(1) var<storage,read> diagnosticPoints:array<vec4<f32>>;
@group(0) @binding(2) var<storage,read_write> diagnosticOutput:array<vec4<f32>>;
@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id:vec3<u32>){
  if(id.x>=${input.length}u){return;}
  let p=diagnosticPoints[id.x];let value=waterSurface(p.xyz,p.w);
  diagnosticOutput[2u*id.x]=vec4(value.offset,value.variance);
  diagnosticOutput[2u*id.x+1u]=vec4(value.normal,value.foam);
}
'''),
      );
      final surfaceBindings = [..._waveBindings, ..._interactionBindings];
      final resources = [for (final b in surfaceBindings) b.resource!];
      final graph = await work.graphs.compile(
        GraphDescription(
          inputs: [locations, output, ...resources],
          passes: [
            ComputePassDescriptor(
              name: 'water-surface-diagnostic',
              program: program,
              workgroups: Workgroups((input.length + 63) ~/ 64),
              reads: [locations, output, ...resources],
              writes: [output],
              bindings: ShaderBindings([
                ...surfaceBindings,
                BufferBinding.storageRead(1, locations),
                BufferBinding.storageReadWrite(2, output),
              ]),
            ),
          ],
        ),
      );
      await graph.execute();
      final bytes = ByteData.sublistView(
        await work.resources.readBuffer(output),
      );
      double f(int i) => bytes.getFloat32(i * 4, Endian.little);
      return List.unmodifiable([
        for (var i = 0; i < input.length; i++)
          OceanWaterSurfaceDebug(
            Vec3(f(i * 8), f(i * 8 + 1), f(i * 8 + 2)),
            Vec3(f(i * 8 + 4), f(i * 8 + 5), f(i * 8 + 6)),
            f(i * 8 + 3),
            foam: f(i * 8 + 7),
          ),
      ]);
    } finally {
      await work.close();
    }
  }

  /// Explicit native qualification of stitched vertex offsets, before scene
  /// transforms. Normal rendering reads the mesh's actual morph weight.
  Future<List<Vec3>> debugStencilOffsets(double fraction) async {
    final vertices = controls;
    if (vertices == null ||
        !fraction.isFinite ||
        fraction < 0 ||
        fraction > 1) {
      throw ArgumentError(
        'Stitched diagnostics require controls and a valid fraction.',
      );
    }
    final work = _scope.createChild(label: 'water-stencil-diagnostic');
    try {
      final output = await work.resources.createBuffer(
        BufferDescriptor(
          size: vertices.vertexCount * 16,
          usage: {BufferUsage.storage, BufferUsage.copySource},
        ),
      );
      final program = await work.shaders.compile(
        ShaderSource.wgsl('''
$_source
@group(0) @binding(1) var<storage,read_write> diagnosticOutput:array<vec4<f32>>;
@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id:vec3<u32>){
  if(id.x>=${vertices.vertexCount}u){return;}
  diagnosticOutput[id.x]=vec4(waterVertexOffset(id.x,vec3(0.),$fraction),0.);
}
'''),
      );
      final bindings = [
        ..._waveBindings,
        ..._interactionBindings,
        TextureBinding.sampled(13, _controlBinding.resource, group: 1),
      ];
      final resources = [for (final b in bindings) b.resource!];
      final graph = await work.graphs.compile(
        GraphDescription(
          inputs: [output, ...resources],
          passes: [
            ComputePassDescriptor(
              name: 'water-stencil-diagnostic',
              program: program,
              workgroups: Workgroups((vertices.vertexCount + 63) ~/ 64),
              reads: [output, ...resources],
              writes: [output],
              bindings: ShaderBindings([
                ...bindings,
                BufferBinding.storageReadWrite(1, output),
              ]),
            ),
          ],
        ),
      );
      await graph.execute();
      final bytes = ByteData.sublistView(
        await work.resources.readBuffer(output),
      );
      double f(int i) => bytes.getFloat32(i * 4, Endian.little);
      return List.unmodifiable([
        for (var i = 0; i < vertices.vertexCount; i++)
          Vec3(f(i * 4), f(i * 4 + 1), f(i * 4 + 2)),
      ]);
    } finally {
      await work.close();
    }
  }

  Future<void> close() => _scope.close();
}

const _hemisphere = '''
fn waterEnvironment(p:vec3<f32>,direction:vec3<f32>,roughness:f32)->vec3<f32> {
  let up=normalize(water.originWeighted.xyz+p*water.inverseRadii.xyz);
  let hemisphere=clamp(.5+.5*dot(direction,up),0.,1.);
  return mix(water.ground.xyz,water.sky.xyz,mix(hemisphere,.5,roughness*roughness));
}
fn waterDirect(p:vec3<f32>)->vec3<f32>{return water.sunIrradiance.xyz;}
fn waterIncident(p:vec3<f32>,normal:vec3<f32>)->vec3<f32>{
  return water.sky.xyz+water.sunIrradiance.xyz*max(0.,dot(normal,water.sunDirection.xyz))*.07957747155;
}
''';

const _atmosphere = '''
fn waterAtmospherePoint(p:vec3<f32>)->vec3<f32>{
  let normal=normalize(water.originWeighted.xyz+p*water.inverseRadii.xyz);
  return normal*(BOTTOM+max(0.,water.originWeighted.w)*.001);
}
fn waterEnvironment(p:vec3<f32>,direction:vec3<f32>,roughness:f32)->vec3<f32>{
  let origin=waterAtmospherePoint(p);let sun=water.sunDirection.xyz;
  let up=normalize(origin);
  // A reflected ray below the mean horizon meets neighbouring water. The sky
  // LUT has no water geometry there and returns dark ground radiance. Use the
  // grazing sky as the unresolved water-reflection fallback; SSR can replace it.
  let horizonDirection=normalize(direction+up*max(0.,.001-dot(direction,up)));
  let axis=select(vec3(0.,0.,1.),vec3(0.,1.,0.),abs(horizonDirection.z)>.9);
  let tangent=normalize(cross(horizonDirection,axis));let bitangent=cross(horizonDirection,tangent);
  let spread=roughness*roughness;
  var value=atmosphereSky(origin,horizonDirection,sun,false).radiance;
  value+=atmosphereSky(origin,normalize(horizonDirection+tangent*spread),sun,false).radiance;
  value+=atmosphereSky(origin,normalize(horizonDirection-tangent*spread),sun,false).radiance;
  value+=atmosphereSky(origin,normalize(horizonDirection+bitangent*spread),sun,false).radiance;
  value+=atmosphereSky(origin,normalize(horizonDirection-bitangent*spread),sun,false).radiance;
  return value*.2;
}
fn waterDirect(p:vec3<f32>)->vec3<f32>{
  return atmosphereSunIrradiance(waterAtmospherePoint(p),water.sunDirection.xyz,water.sunDirection.xyz);
}
fn waterIncident(p:vec3<f32>,normal:vec3<f32>)->vec3<f32>{
  return atmosphereSkyIrradiance(waterAtmospherePoint(p),normal,water.sunDirection.xyz)*.31830988618+
    waterDirect(p)*max(0.,dot(normal,water.sunDirection.xyz))*.07957747155;
}
''';

const _environment = '''
@group(1) @binding(7) var waterSpecular:texture_3d<f32>;
@group(1) @binding(8) var waterIrradiance:texture_2d<f32>;
@group(1) @binding(9) var waterEnvironmentSampler:sampler;
fn waterEnvironmentUv(direction:vec3<f32>)->vec2<f32>{
  return vec2(fract(atan2(direction.z,direction.x)/6.28318530718+.5+water.environment.y/6.28318530718),acos(clamp(direction.y,-1.,1.))/3.14159265359);
}
fn waterEnvironment(p:vec3<f32>,direction:vec3<f32>,roughness:f32)->vec3<f32>{
  let levels=f32(textureDimensions(waterSpecular).z);
  let uv=vec3(waterEnvironmentUv(direction),(roughness*(levels-1.)+.5)/levels);
  return textureSampleLevel(waterSpecular,waterEnvironmentSampler,uv,0.).rgb*water.environment.x;
}
fn waterDirect(p:vec3<f32>)->vec3<f32>{return water.sunIrradiance.xyz;}
fn waterIncident(p:vec3<f32>,normal:vec3<f32>)->vec3<f32>{
  return textureSampleLevel(waterIrradiance,waterEnvironmentSampler,waterEnvironmentUv(normal),0.).rgb*water.environment.x*.31830988618+
    water.sunIrradiance.xyz*max(0.,dot(normal,water.sunDirection.xyz))*.07957747155;
}
''';

/// Visual-field diagnostic, without physical coverage or inverse-query guarantees.
final class OceanWaterSurfaceDebug {
  final Vec3 offsetEcef, normalEcef;
  final double unresolvedSlopeVariance, foam;
  const OceanWaterSurfaceDebug(
    this.offsetEcef,
    this.normalEcef,
    this.unresolvedSlopeVariance, {
    this.foam = 0,
  });
}

/// Scoped visual wave inputs for custom compute or procedural rendering passes.
final class OceanWaveShaderInputs {
  final String wgsl;
  final List<ShaderBinding> bindings;
  OceanWaveShaderInputs._(this.wgsl, Iterable<ShaderBinding> bindings)
    : bindings = List.unmodifiable(bindings);
}
