import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'material.dart';
import 'lighting.dart';
import 'underwater.dart';
import 'caustics_wgsl.dart';

/// Bounded projected sunlight on a local tangent receiver plane. The native
/// pass refracts the actual filtered wave triangles, accumulates overlapping
/// projections and limits integrated irradiance to the incident horizontal flux.
/// It excludes underwater occluders unless you supply projected visibility.
final class OceanCaustics {
  final GpuScope _scope;
  final GpuResource<Texture> texture;
  final Vec3 anchorEcef, east, north, up;
  final double extentMetres, depthMetres, seconds;
  final int resolution, logicalBytes;
  final bool hasShadowVisibility;
  final Vec3 sunIrradiance, sunDirectionEcef;
  final OceanMediumLighting _lighting;
  bool get isClosed => _scope.isClosed;
  OceanCaustics._(
    this._scope,
    this.texture,
    this.anchorEcef,
    this.east,
    this.north,
    this.up,
    this.extentMetres,
    this.depthMetres,
    this.seconds,
    this.resolution,
    this.logicalBytes,
    this.hasShadowVisibility,
    this.sunIrradiance,
    this.sunDirectionEcef,
    this._lighting,
  );

  /// Null means caustics are disabled, with no allocation or graph dispatch.
  /// Keep the footprint inside the source patch so all required charts reside.
  static Future<OceanCaustics?> create(
    GpuScope parent, {
    required OceanWaterMaterial water,
    required OceanUnderwaterSettings settings,
    required double extentMetres,
    required double depthMetres,
    double maximumConcentration = 4,
    OceanSunVisibility? visibility,
    int maxLogicalBytes = 64 * 1024 * 1024,
  }) async {
    final size = settings.causticResolution;
    if (water.isClosed) throw StateError('Water material closed.');
    if (!extentMetres.isFinite ||
        extentMetres <= 0 ||
        extentMetres > 4096 ||
        !depthMetres.isFinite ||
        depthMetres <= 0 ||
        depthMetres > 1000 ||
        !maximumConcentration.isFinite ||
        maximumConcentration < 1 ||
        maximumConcentration > 8) {
      throw ArgumentError('Invalid caustic footprint, depth or concentration.');
    }
    if (size == 0) return null;
    final origin = water.originEcef;
    final anchor = water.ellipsoid.projectOnSurface(origin);
    final basis = water.ellipsoid.eastNorthUpVectors(anchor);
    for (final u in [-.5, .5]) {
      for (final v in [-.5, .5]) {
        final point =
            anchor +
            basis.east * (u * extentMetres) +
            basis.north * (v * extentMetres);
        final uv = water.patch.localCoordinates(point);
        if (uv.u < 0 || uv.u > 1 || uv.v < 0 || uv.v > 1) {
          throw ArgumentError(
            'Caustic footprint must fit inside the source patch.',
          );
        }
      }
    }
    final pixels = size * size, groups = (pixels + 255) ~/ 256;
    final bytes =
        pixels * 16 + groups * 16 + 16 + 160 + (visibility == null ? 16 : 0);
    if (maxLogicalBytes < 1 || bytes > maxLogicalBytes) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Caustic passes exceed their logical byte allowance.',
      );
    }
    final scope = parent.createChild(label: 'ocean-caustics');
    try {
      final field = await water.retainWaveInputs(scope);
      final lighting = await OceanMediumLighting.create(scope, water.lighting);
      final uniform = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 160,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final raw = await scope.resources.createTexture(
        TextureDescriptor(
          width: size,
          height: size,
          format: TextureFormat.rgba16Float,
          usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
        ),
      );
      final output = await scope.resources.createTexture(
        TextureDescriptor(
          width: size,
          height: size,
          format: TextureFormat.rgba16Float,
          usage: {
            TextureUsage.sampled,
            TextureUsage.storage,
            TextureUsage.copySource,
          },
        ),
      );
      final partial = await scope.resources.createBuffer(
        BufferDescriptor(size: groups * 16, usage: {BufferUsage.storage}),
      );
      final normalization = await scope.resources.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.storage}),
      );
      final shadow = visibility == null
          ? await scope.resources.createTexture(
              TextureDescriptor(
                width: 1,
                height: 1,
                format: TextureFormat.rgba32Float,
                usage: {TextureUsage.sampled},
              ),
            )
          : await scope.resources.retain(visibility.texture);
      final radius = water.ellipsoid.maximumRadius;
      final inverse = water.ellipsoid.reciprocalRadiiSquared;
      final error =
          (origin.x * origin.x * inverse.x +
              origin.y * origin.y * inverse.y +
              origin.z * origin.z * inverse.z -
              1) *
          radius;
      final relative = anchor - origin;
      final shadowAnchor = visibility == null
          ? Vec3.zero
          : origin - visibility.anchor;
      final values = Float32List.fromList([
        ...relative.storage,
        extentMetres,
        ...basis.east.storage,
        depthMetres,
        ...basis.north.storage,
        maximumConcentration,
        ...basis.up.storage,
        size.toDouble(),
        error,
        groups.toDouble(),
        visibility == null ? 0 : 1,
        0,
        ...shadowAnchor.storage,
        0,
        ...(visibility?.uPerMetre ?? Vec3.zero).storage,
        0,
        ...(visibility?.vPerMetre ?? Vec3.zero).storage,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      await scope.resources.writeBuffer(uniform, values);
      final source = field.wgsl + oceanCausticsWgsl;
      final program = await scope.shaders.compile(
        ShaderSource.wgsl(source, label: 'ocean-caustics'),
      );
      final bindings = [
        ...field.bindings,
        BufferBinding.uniform(0, uniform, group: 0),
        TextureBinding.sampled(1, shadow, group: 0),
      ];
      final waveResources = [
        for (final binding in field.bindings) binding.resource!,
      ];
      final reduceBindings = ShaderBindings([
        BufferBinding.uniform(0, uniform, group: 0),
        TextureBinding.sampled(2, raw, group: 0),
        BufferBinding.storageReadWrite(3, partial, group: 0),
        BufferBinding.storageReadWrite(4, normalization, group: 0),
        ...field.bindings.take(1),
      ]);
      final graph = await scope.graphs.compile(
        GraphDescription(
          inputs: [
            uniform,
            shadow,
            raw,
            output,
            partial,
            normalization,
            ...waveResources,
          ],
          passes: [
            RenderPassDescriptor(
              name: 'caustic projection',
              program: program,
              color: ColorAttachment(raw),
              blend: RenderBlend.additive,
              vertexCount: pixels * 6,
              bindings: ShaderBindings(bindings),
              reads: [uniform, shadow, ...waveResources],
              writes: [raw],
            ),
            ComputePassDescriptor(
              name: 'caustic partial flux',
              program: program,
              entryPoint: 'partialFlux',
              workgroups: Workgroups(groups),
              bindings: reduceBindings,
              reads: [
                uniform,
                raw,
                partial,
                normalization,
                waveResources.first,
              ],
              writes: [partial, normalization],
              after: {'caustic projection'},
            ),
            ComputePassDescriptor(
              name: 'caustic total flux',
              program: program,
              entryPoint: 'totalFlux',
              workgroups: const Workgroups(1),
              bindings: reduceBindings,
              reads: [
                uniform,
                raw,
                partial,
                normalization,
                waveResources.first,
              ],
              writes: [partial, normalization],
              after: {'caustic partial flux'},
            ),
            ComputePassDescriptor(
              name: 'caustic bounded output',
              program: program,
              entryPoint: 'resolve',
              workgroups: Workgroups((size + 7) ~/ 8, (size + 7) ~/ 8),
              bindings: ShaderBindings([
                ...reduceBindings.entries,
                TextureBinding.storage(5, output, group: 0),
              ]),
              reads: [
                uniform,
                raw,
                partial,
                normalization,
                waveResources.first,
              ],
              writes: [partial, normalization, output],
              after: {'caustic total flux'},
            ),
          ],
        ),
      );
      await graph.execute();
      return OceanCaustics._(
        scope,
        output,
        anchor,
        basis.east,
        basis.north,
        basis.up,
        extentMetres,
        depthMetres,
        water.seconds,
        size,
        bytes,
        visibility != null,
        water.lighting.sunIrradiance,
        water.lighting.sunDirectionEcef.normalized(),
        lighting,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  /// A Lambertian planar receiver with ambient radiance and this pass's direct
  /// sunlight. Geometry positions and normals use local ECEF axes, relative to
  /// [geometryOriginEcef]. Keep its physical transform in metres. This material
  /// supplies direct sunlight itself, including light-path water attenuation.
  Future<ShaderMaterial> createReceiverMaterial(
    GpuScope owner, {
    Vec3? geometryOriginEcef,
    Color3 albedo = const Color3(1, 1, 1),
    Vec3 ambientRadiance = Vec3.zero,
    double receiverThicknessMetres = .25,
  }) async {
    if (isClosed) throw StateError('Caustic map closed.');
    final origin = geometryOriginEcef ?? anchorEcef;
    if (!origin.isFinite ||
        !ambientRadiance.isFinite ||
        ambientRadiance.storage.any((v) => v < 0 || v > 65504) ||
        !receiverThicknessMetres.isFinite ||
        receiverThicknessMetres <= 0 ||
        receiverThicknessMetres > 10) {
      throw ArgumentError(
        'Invalid caustic receiver position, radiance or thickness.',
      );
    }
    final uniform = await owner.resources.createBuffer(
      BufferDescriptor(
        size: 128,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    await owner.resources.writeBuffer(
      uniform,
      Float32List.fromList([
        ...(origin - anchorEcef).storage,
        extentMetres,
        ...east.storage,
        depthMetres,
        ...north.storage,
        receiverThicknessMetres,
        ...up.storage,
        0,
        ...sunIrradiance.storage,
        0,
        ...ambientRadiance.storage,
        0,
        ...albedo.toList(),
        0,
        ...sunDirectionEcef.storage,
        0,
      ]),
    );
    final retained = await owner.resources.retain(texture);
    final lighting = await _lighting.retain(owner);
    final program = await owner.shaders.compileMesh(
      ShaderSource.wgsl(
        '${MeshShaderInterface.wgsl}\n${lighting.wgsl}\n$oceanCausticReceiverWgsl',
        label: 'ocean-caustic-receiver',
      ),
      bindings: ShaderBindings([
        ...lighting.bindings,
        BufferBinding.uniform(0, uniform, group: 1),
        TextureBinding.sampled(1, retained, group: 1),
      ]),
    );
    return ShaderMaterial(program, side: MaterialSide.doubleSided);
  }

  Future<void> close() => _scope.close();
}
