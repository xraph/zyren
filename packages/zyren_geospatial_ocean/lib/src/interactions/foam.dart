import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../rendering/material.dart';
import 'field.dart';
import 'foam_wgsl.dart';

/// Positive depth below the declared mean water surface, in metres. NaN means
/// unknown coverage. This immutable input carries source identity and revision;
/// callers obtain authorized data through their geospatial resolver.
final class OceanFoamDepthMap {
  final String sourceId, revision;
  final double meanLevelMetres;
  final GeoScalarGrid grid;
  OceanFoamDepthMap({
    required this.sourceId,
    required this.revision,
    required this.meanLevelMetres,
    required this.grid,
  }) {
    if (sourceId.trim().isEmpty ||
        revision.trim().isEmpty ||
        sourceId.length > 256 ||
        revision.length > 256 ||
        !meanLevelMetres.isFinite ||
        meanLevelMetres.abs() > 1e5 ||
        grid.values.any((v) => v.isFinite && (v < 0 || v > 12000))) {
      throw ArgumentError(
        'Foam depth needs bounded depth below a declared mean surface.',
      );
    }
  }
}

final class OceanFoamSettings {
  final double compressionThreshold,
      whitecapRate,
      shoreRate,
      shoreDepthMetres,
      shoreSlope;
  OceanFoamSettings({
    this.compressionThreshold = .85,
    this.whitecapRate = 4,
    this.shoreRate = 3,
    this.shoreDepthMetres = 2,
    this.shoreSlope = .3,
  }) {
    if (!compressionThreshold.isFinite ||
        compressionThreshold <= 0 ||
        compressionThreshold > 1 ||
        !whitecapRate.isFinite ||
        whitecapRate < 0 ||
        whitecapRate > 100 ||
        !shoreRate.isFinite ||
        shoreRate < 0 ||
        shoreRate > 100 ||
        !shoreDepthMetres.isFinite ||
        shoreDepthMetres <= 0 ||
        shoreDepthMetres > 100 ||
        !shoreSlope.isFinite ||
        shoreSlope <= 0 ||
        shoreSlope > 10) {
      throw ArgumentError('Invalid bounded foam emission settings.');
    }
  }
}

/// Reusable native emission from the filtered spectral surface. Compression
/// drives whitecaps; positive, covered shallow depth and wave slope drive shore
/// foam. Calm water and missing depth do not fabricate shore breakers.
final class OceanFoamProducer {
  final GpuScope _scope;
  final CompiledGraph _graph;
  final OceanWaterMaterial water;
  final OceanInteractionField field;
  final Vec3 anchorEcef;
  final OceanFoamSettings settings;
  final OceanFoamDepthMap? depth;
  final int logicalBytes;
  Future<void>? _pending, _closing;
  bool _closed = false;
  bool get isClosed => _closed || _scope.isClosed;
  OceanFoamProducer._(
    this._scope,
    this._graph,
    this.water,
    this.field,
    this.anchorEcef,
    this.settings,
    this.depth,
    this.logicalBytes,
  );

  static Future<OceanFoamProducer> create(
    GpuScope parent, {
    required OceanWaterMaterial water,
    required OceanInteractionField field,
    OceanFoamSettings? settings,
    OceanFoamDepthMap? depth,
    int maxLogicalBytes = 8 * 1024 * 1024,
  }) async {
    if (water.isClosed || !field.isReady) {
      throw StateError('Foam inputs are not ready.');
    }
    if (depth != null &&
        (depth.meanLevelMetres - water.meanLevelMetres).abs() > 1e-6) {
      throw ArgumentError(
        'Foam depth and water must share a mean surface level.',
      );
    }
    final options = settings ?? OceanFoamSettings(), anchor = field.anchorEcef;
    final n = field.settings.resolution, extent = field.settings.extentMetres;
    final bytes = 96 + n * n * 16;
    if (maxLogicalBytes < bytes) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Foam source map exceeds its allowance.',
      );
    }
    // The water contract supplies a complete set of chart textures only inside
    // its declared patch. A producer must not quietly read absent charts.
    for (final x in [-.5, .5]) {
      for (final y in [-.5, .5]) {
        final uv = water.patch.localCoordinates(
          anchor + field.east * (x * extent) + field.north * (y * extent),
        );
        if (uv.u < 0 || uv.u > 1 || uv.v < 0 || uv.v > 1) {
          throw ArgumentError(
            'Foam window must fit within the source water patch.',
          );
        }
      }
    }
    final scope = parent.createChild(label: 'ocean-foam-emission');
    try {
      final wave = await water.retainWaveInputs(scope);
      final output = await scope.resources.retain(field.foamSources);
      final config = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 96,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final depths = await scope.resources.createTexture(
        TextureDescriptor(
          width: n,
          height: n,
          format: TextureFormat.rgba32Float,
          usage: {TextureUsage.sampled, TextureUsage.copyDestination},
        ),
      );
      final upload = Float32List(n * n * 4);
      if (depth != null) {
        for (var y = 0; y < n; y++) {
          for (var x = 0; x < n; x++) {
            final position =
                anchor +
                field.east * ((x / (n - 1) - .5) * extent) +
                field.north * ((y / (n - 1) - .5) * extent);
            final d = depth.grid.at(
              water.ellipsoid.fromEcef(position),
              GeoFieldInterpolation.bilinear,
            );
            if (d != null) {
              upload[(y * n + x) * 4] = d;
              upload[(y * n + x) * 4 + 1] = 1;
            }
          }
        }
      }
      await scope.resources.writeTexture(depths, upload);
      final delta = anchor - water.originEcef;
      await scope.resources.writeBuffer(
        config,
        Float32List.fromList([
          delta.x,
          delta.y,
          delta.z,
          extent,
          field.east.x,
          field.east.y,
          field.east.z,
          n.toDouble(),
          field.north.x,
          field.north.y,
          field.north.z,
          options.compressionThreshold,
          field.up.x,
          field.up.y,
          field.up.z,
          options.whitecapRate,
          options.shoreRate,
          options.shoreDepthMetres,
          options.shoreSlope,
          depth?.meanLevelMetres ?? 0,
          0,
          0,
          0,
          0,
        ]),
      );
      final program = await scope.shaders.compile(
        ShaderSource.wgsl(
          '${wave.wgsl}\n$oceanFoamWgsl',
          label: 'ocean-foam-emission',
        ),
      );
      final inputs = [
        config,
        depths,
        for (final b in wave.bindings) b.resource!,
      ];
      final graph = await scope.graphs.compile(
        GraphDescription(
          inputs: inputs,
          passes: [
            ComputePassDescriptor(
              name: 'foam-emission',
              program: program,
              workgroups: Workgroups((n + 7) ~/ 8, (n + 7) ~/ 8),
              reads: inputs,
              writes: [output],
              bindings: ShaderBindings([
                ...wave.bindings,
                BufferBinding.uniform(0, config),
                TextureBinding.sampled(1, depths),
                TextureBinding.storage(2, output),
              ]),
            ),
          ],
        ),
      );
      if (!field.isReady || anchor != field.anchorEcef || water.isClosed) {
        throw StateError('Foam inputs changed during preparation.');
      }
      return OceanFoamProducer._(
        scope,
        graph,
        water,
        field,
        anchor,
        options,
        depth,
        bytes,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  /// Recreate this producer after recentering to resample covered bathymetry.
  /// Await update before stepping the field. No readback occurs here.
  Future<void> update() {
    if (isClosed ||
        water.isClosed ||
        _pending != null ||
        !field.isReady ||
        anchorEcef != field.anchorEcef) {
      return Future.error(
        StateError('Foam producer is closed, busy or has a stale window.'),
      );
    }
    return _pending = field
        .updateFoamSources(() async {
          await _graph.execute();
        })
        .whenComplete(() {
          _pending = null;
        });
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    try {
      await _pending;
    } finally {
      await _scope.close();
    }
  }
}
