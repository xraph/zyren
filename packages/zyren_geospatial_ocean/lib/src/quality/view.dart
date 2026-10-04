import 'dart:async';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart' show CaptureBackend, SceneCaptureView;
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../surface/cube_patch.dart';
import '../surface/geometry.dart';
import '../surface/morph.dart';
import '../surface/selector.dart';
import '../rendering/material.dart';
import '../rendering/programs.dart';
import '../rendering/water_geometry.dart';
import '../rendering/wave_render_data.dart';
import '../rendering/lighting.dart';
import '../rendering/optics.dart';
import '../rendering/surface_capture.dart';
import '../rendering/underwater.dart';
import '../rendering/water_volume.dart';
import '../rendering/caustics.dart';
import '../interactions/field.dart';
import 'settings.dart';
import 'admission.dart';
import 'controller.dart';
import 'diagnostics.dart';

/// A successful camera surface query in the same ECEF frame and wave instant.
/// Supply an actual physical/visual query result. Missing water is not zero depth.
final class OceanCameraWaterSample {
  final Vec3 positionEcef, upEcef;
  final double seconds, signedDistanceMetres;
  OceanCameraWaterSample({
    required this.positionEcef,
    required this.upEcef,
    required this.seconds,
    required this.signedDistanceMetres,
  }) {
    if (!positionEcef.isFinite ||
        !upEcef.isFinite ||
        (upEcef.length - 1).abs() > 1e-8 ||
        !seconds.isFinite ||
        !signedDistanceMetres.isFinite) {
      throw ArgumentError('Invalid camera water sample.');
    }
  }
}

final class OceanViewUnderwater {
  final FutureOr<OceanCameraWaterSample?> Function(
    Camera,
    OceanPresentationFrame,
  )
  sampleCamera;
  final OceanWaterVolume? volume;
  final OceanSunVisibility? sunVisibility;

  /// Exposes the medium map for the host atmosphere pass. The host must bind it.
  final bool mediumTransport;
  OceanViewUnderwater({
    required this.sampleCamera,
    this.volume,
    this.sunVisibility,
    this.mediumTransport = false,
  });
}

/// One bounded, explicit projection region. Receivers can consume its generated
/// map through OceanCaustics.createReceiverMaterial; no seabed is invented here.
final class OceanCausticRegion {
  final String id;
  final OceanPatchId patch;
  final double extentMetres, depthMetres;
  final OceanSunVisibility? visibility;
  OceanCausticRegion({
    required this.id,
    required this.patch,
    required this.extentMetres,
    required this.depthMetres,
    this.visibility,
  }) {
    if (id.trim().isEmpty ||
        id.length > 48 ||
        !extentMetres.isFinite ||
        extentMetres <= 0 ||
        extentMetres > 4096 ||
        !depthMetres.isFinite ||
        depthMetres <= 0 ||
        depthMetres > 1000) {
      throw ArgumentError('Invalid view caustic region.');
    }
  }
}

/// A fixed native viewport with ECEF scene coordinates. The camera may move;
/// topology is selected when planning. Rebuild the recipe to refine a new route.
/// Atmosphere, environments and interaction fields are borrowed shared inputs.
final class OceanViewConfiguration {
  final String id;
  final Camera camera;
  final PhysicalSize size;
  final Ellipsoid ellipsoid;
  final int sampleCount;
  final double displacementBoundMetres;
  final OceanOptics optics;
  final OceanLighting lighting;
  final OceanWaterDebug debug;

  /// The host must install this same fog in its atmosphere inputs. Geometry
  /// beyond its opaque limit is skipped; physical water queries are unaffected.
  final GeoDistanceFog? fog;
  final OceanInteractionField? interactions;
  final OceanViewUnderwater? underwater;
  final List<OceanCausticRegion> caustics;
  OceanViewConfiguration({
    required this.id,
    required this.camera,
    required this.size,
    required this.displacementBoundMetres,
    this.ellipsoid = Ellipsoid.wgs84,
    this.sampleCount = 1,
    OceanOptics? optics,
    OceanLighting? lighting,
    this.debug = OceanWaterDebug.color,
    this.fog,
    this.interactions,
    this.underwater,
    Iterable<OceanCausticRegion> caustics = const [],
  }) : optics = optics ?? OceanOptics(),
       lighting = lighting ?? OceanLighting(),
       caustics = List.unmodifiable(caustics.take(9)) {
    if (camera is! PerspectiveCamera && camera is! OrthographicCamera) {
      throw ArgumentError(
        'Ocean views need a perspective or orthographic camera.',
      );
    }
    OceanViewAllocation(id: id, size: size, sampleCount: sampleCount);
    if (id.length > 48 ||
        (underwater != null && size.width * size.height > 2073600)) {
      throw ArgumentError(
        'Ocean view exceeds its name or capture pixel limit.',
      );
    }
    if (!displacementBoundMetres.isFinite ||
        displacementBoundMetres < 0 ||
        displacementBoundMetres > 1e6 ||
        this.caustics.length > 8 ||
        this.caustics.map((c) => c.id).toSet().length != this.caustics.length) {
      throw ArgumentError('Invalid ocean view bound or caustic regions.');
    }
  }
}

/// Native view bundles prepared under an OceanController. The plan owns its
/// geometry, water materials, boundary capture, underwater pass and caustic maps.
/// Spray remains an optional fixed-tick particle adapter outside this package.
final class OceanViewSet {
  final Map<String, OceanViewResources> views;
  OceanViewSet._(Map<String, OceanViewResources> views)
    : views = Map.unmodifiable(views);
  OceanViewResources view(String id) =>
      views[id] ?? (throw ArgumentError('Unknown ocean view $id.'));
  int get patchCount => views.values.fold(0, (n, v) => n + v.patchCount);
  int get vertexCount => views.values.fold(0, (n, v) => n + v.vertexCount);
  List<OceanPassMeasurement> get measurements => [
    for (final view in views.values) ...view.measurements,
  ];

  static OceanQualityPlan<OceanViewSet> plan({
    required OceanQualitySettings settings,
    required Iterable<OceanViewConfiguration> views,
    CaptureBackend? captureBackend,
    Future<SceneCaptureView> Function()? captureViewFactory,
    OceanViewSet? previous,
  }) {
    final configs = views.take(9).toList();
    if (configs.isEmpty ||
        configs.length > 8 ||
        configs.map((v) => v.id).toSet().length != configs.length) {
      throw ArgumentError('Ocean recipes require 1..8 unique views.');
    }
    if (captureBackend != null && captureViewFactory != null) {
      throw ArgumentError('Supply one capture provider.');
    }
    final createCapture =
        captureViewFactory ?? captureBackend?.createCaptureView;
    if (configs.any((v) => v.underwater != null) && createCapture == null) {
      throw OceanQualityException(
        OceanQualityErrorCode.unsupportedFeature,
        'Underwater views require a native capture backend.',
        missingFeatures: {RenderFeature.sceneCapture},
      );
    }
    if (previous != null &&
        (previous.views.length != configs.length ||
            configs.any(
              (v) => !identical(previous.views[v.id]?.configuration, v),
            ))) {
      throw OceanQualityException(
        OceanQualityErrorCode.incompatibleTransition,
        'A quality fade must retain the same view configurations.',
      );
    }
    final recipes = [
      for (final config in configs)
        _ViewRecipe(config, settings, previous?.views[config.id]),
    ];
    return OceanQualityPlan(
      views: [for (final r in recipes) r.allocation],
      additionalPayloads: {
        for (final r in recipes)
          if (r.causticBytes > 0) 'caustics:${r.config.id}': r.causticBytes,
      },
      requiredFeatures: {
        if (previous != null) RenderFeature.morphTargets,
        if (configs.any((c) => c.underwater != null))
          RenderFeature.postprocessing,
      },
      activeEffects: {
        'surface',
        if (settings.ssrSteps > 0) 'screenSpaceReflection',
        if (configs.any((c) => c.interactions != null)) 'interactions',
        if (configs.any((c) => c.underwater != null)) 'underwater',
        if (settings.shaftSteps > 0 && configs.any((c) => c.underwater != null))
          'shafts',
        if (recipes.any((r) => r.causticBytes > 0)) 'caustics',
      },
      build: (context, waves) async {
        final built = <String, OceanViewResources>{};
        for (final recipe in recipes) {
          final view = OceanViewResources._(recipe, waves);
          context.onClose(view.close);
          await view._build(context.gpu, createCapture);
          built[recipe.config.id] = view;
        }
        return OceanViewSet._(built);
      },
      prepareFrame: (set, frame) async {
        for (final view in set.views.values) {
          await view._prepare(frame);
        }
      },
    );
  }
}

final class _ViewRecipe {
  final OceanViewConfiguration config;
  final OceanQualitySettings settings;
  late final OceanSurfaceSelection selection;
  late final OceanSurfaceGeometry surface;
  late final OceanWaterGeometry controls;
  final bool morphing;
  _ViewRecipe(this.config, this.settings, OceanViewResources? previous)
    : morphing = previous != null {
    if (previous != null && previous.surface.segments != settings.segments) {
      throw OceanQualityException(
        OceanQualityErrorCode.incompatibleTransition,
        'Segment changes require a zero-duration replacement.',
      );
    }
    selection = selectOceanSurface(
      config.camera,
      ViewportMetrics(
        config.size.width.toDouble(),
        config.size.height.toDouble(),
      ),
      config.ellipsoid,
      settings.lod,
      displacementBoundMetres: config.displacementBoundMetres,
      fog: config.fog,
    );
    surface = OceanSurfaceGeometry(
      selection.allPatches,
      ellipsoid: config.ellipsoid,
      segments: settings.segments,
      maxVertices: settings.maxVertices,
    );
    // Reject large CPU stencil builds from their exact grid layout first.
    final common = {
      ...surface.topology.patches,
      ...?previous?.surface.topology.patches,
    };
    for (final patch in common.toList()) {
      for (var parent = patch.parent; parent != null; parent = parent.parent) {
        common.remove(parent);
      }
    }
    final vertices = (settings.segments + 1) * (settings.segments + 1);
    final stencilBytes = ((vertices * 24 + 255) ~/ 256) * 256 * 16;
    final geometryBytes =
        vertices * (morphing ? 76 : 40) +
        settings.segments * settings.segments * 24 +
        (morphing ? 272 : 0);
    final bytes =
        common.length *
        (1104 +
            stencilBytes +
            geometryBytes * (config.underwater == null ? 1 : 2));
    final limit = math.max(
      settings.gpuBudgetBytes,
      previous?.quality.gpuBudgetBytes ?? 0,
    );
    if (bytes > limit) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Ocean view geometry and controls exceed the resource allowance.',
      );
    }
    controls = previous == null
        ? OceanWaterGeometry.fromSurface(surface)
        : OceanWaterGeometry.fromMorph(
            OceanSurfaceMorph(
              previous.surface,
              surface,
              maxVertices: math.min(
                18000000,
                previous.surface.vertexCount + surface.vertexCount,
              ),
            ),
          );
  }
  int get causticBytes => settings.causticResolution == 0
      ? 0
      : config.caustics.fold(0, (sum, c) {
          final pixels =
              settings.causticResolution * settings.causticResolution;
          return sum +
              1104 +
              pixels * 16 +
              ((pixels + 255) ~/ 256) * 16 +
              176 +
              (c.visibility == null ? 16 : 0);
        });
  OceanViewAllocation get allocation {
    final underwater = config.underwater;
    // Each native scene view may retain a geometry/pose copy. Count both the
    // presentation and boundary view, including the fixed 272-byte morph pose.
    final geometry = controls.patches.fold(
      0,
      (sum, c) =>
          sum +
          c.geometry.geometry.capture().gpuByteLength +
          (morphing ? 272 : 0),
    );
    final materials = controls.patches.fold(
      0,
      (sum, c) => sum + 1104 + c.logicalBytes,
    );
    return OceanViewAllocation(
      id: config.id,
      size: config.size,
      sampleCount: config.sampleCount,
      geometryBytes: geometry * (underwater == null ? 1 : 2),
      materialBytes:
          materials +
          (underwater == null
              ? 0
              : 16 + 448 + (underwater.sunVisibility == null ? 16 : 0)),
      boundaryCapture: underwater != null,
      mediumTransport: underwater?.mediumTransport ?? false,
    );
  }
}

final class OceanViewResources {
  static final _owners = Expando<OceanViewResources>('ocean-view-owner');
  final _ViewRecipe _recipe;
  final OceanWaveRenderInputs _waves;
  final Group root = Group(name: 'ocean-surface');
  final List<OceanWaterMaterial> _water = [];
  final List<Mesh> _meshes = [];
  final List<({Vec3 center, double radius})> _fogBounds = [];
  final Map<String, OceanCaustics> _caustics = {};
  final List<FutureOr<void> Function()> _cleanup = [];
  final Map<String, OceanPassMeasurement> _measurements = {};
  OceanSurfaceCapture? _boundary;
  OceanUnderwaterPass? _underwater;
  Scene? _scene;
  double? _originalScale;
  bool _closed = false, _prepared = false, _underwaterVisible = true;
  Future<void>? _closing;
  OceanViewResources._(this._recipe, this._waves);
  OceanViewConfiguration get configuration => _recipe.config;
  OceanQualitySettings get quality => _recipe.settings;
  OceanSurfaceSelection get selection => _recipe.selection;
  OceanSurfaceGeometry get surface => _recipe.surface;
  bool get isMorphing => _recipe.morphing;
  bool get isClosed => _closed;
  bool get isReady =>
      !_closed &&
      _prepared &&
      _waves.isReady &&
      _water.every((w) => w.isReady) &&
      _caustics.values.every((c) => c.isCurrent);
  int get patchCount => _meshes.length;
  int get visiblePatchCount =>
      root.visible ? _meshes.where((mesh) => mesh.visible).length : 0;
  int get vertexCount =>
      _meshes.fold(0, (sum, m) => sum + m.geometry.vertexCount);
  List<OceanWaterMaterial> get water => List.unmodifiable(_water);
  List<Mesh> get meshes => List.unmodifiable(_meshes);
  Map<String, OceanCaustics> get caustics => Map.unmodifiable(_caustics);
  OceanUnderwaterPass? get underwater => _underwater;
  List<OceanPassMeasurement> get measurements =>
      List.unmodifiable(_measurements.values);

  Future<void> _build(
    GpuScope parent,
    Future<SceneCaptureView> Function()? createCapture,
  ) async {
    final config = configuration;
    final scope = parent.createChild(label: 'ocean-view:${config.id}');
    _cleanup.add(scope.close);
    final programs = OceanWaterPrograms(scope);
    _cleanup.add(programs.close);
    for (final control in _recipe.controls.patches) {
      final water = await OceanWaterMaterial.create(
        scope,
        waves: _waves,
        programs: programs,
        patch: control.geometry.id,
        ellipsoid: config.ellipsoid,
        geometrySpacingMetres:
            2 *
            config.ellipsoid.maximumRadius /
            ((1 << control.geometry.id.level) * quality.segments),
        controls: control,
        optics: config.optics,
        lighting: config.lighting,
        reflections: quality.reflections,
        debug: config.debug,
        interactions: config.interactions,
      );
      _cleanup.add(water.close);
      _water.add(water);
      final mesh = water.createMesh(control.geometry);
      if (isMorphing) mesh.morphWeights = [0];
      _meshes.add(mesh);
      if (config.fog != null) {
        final center = control.geometry.origin;
        var radius = 0.0;
        for (var vertex = 0; vertex < control.vertexCount; vertex++) {
          for (final fraction in [0.0, 1.0]) {
            radius = math.max(
              radius,
              center.distanceTo(
                control.evaluateVertex(vertex, fraction, (_, _) => Vec3.zero),
              ),
            );
          }
        }
        _fogBounds.add((
          center: center,
          radius:
              radius +
              config.displacementBoundMetres +
              water.meanLevelMetres.abs() +
              .01,
        ));
      }
      root.add(mesh);
    }
    if (config.underwater case final inputs?) {
      final capture = await OceanSurfaceCapture.createWithViewFactory(
        scope,
        createView: createCapture!,
        draws: [
          for (var i = 0; i < _water.length; i++)
            OceanBoundaryDraw(
              water: _water[i],
              mesh: _meshes[i],
              includeHidden: true,
            ),
        ],
        size: config.size,
      );
      _boundary = capture;
      _cleanup.add(capture.close);
      final underwater = await OceanUnderwaterPass.create(
        scope,
        surface: capture,
        settings: quality.underwater,
        optics: config.optics,
        lighting: config.lighting,
        volume: inputs.volume,
        sunVisibility: inputs.sunVisibility,
        transportSize: inputs.mediumTransport ? config.size : null,
      );
      _underwater = underwater;
      _cleanup.add(underwater.close);
    }
    if (quality.causticResolution > 0) {
      for (final region in config.caustics) {
        final water = await OceanWaterMaterial.create(
          scope,
          waves: _waves,
          programs: programs,
          patch: region.patch,
          ellipsoid: config.ellipsoid,
          geometrySpacingMetres:
              region.extentMetres / quality.causticResolution,
          optics: config.optics,
          lighting: config.lighting,
          reflections: quality.reflections,
        );
        _cleanup.add(water.close);
        final caustic = (await OceanCaustics.create(
          scope,
          water: water,
          settings: quality.underwater,
          extentMetres: region.extentMetres,
          depthMetres: region.depthMetres,
          visibility: region.visibility,
        ))!;
        _caustics[region.id] = caustic;
        _cleanup.add(caustic.close);
      }
    }
  }

  Future<void> _measure(
    String name,
    Future<void> Function() work, {
    int? Function()? dispatches,
    int? Function()? draws,
  }) async {
    final watch = Stopwatch()..start();
    var status = OceanPassStatus.failed;
    try {
      await work();
      status = OceanPassStatus.executed;
    } finally {
      watch.stop();
      _measurements[name] = OceanPassMeasurement(
        name: name,
        status: status,
        hostElapsed: watch.elapsed,
        dispatches: status == OceanPassStatus.executed
            ? dispatches?.call()
            : null,
        drawCalls: status == OceanPassStatus.executed ? draws?.call() : null,
      );
    }
  }

  Future<void> _prepare(OceanPresentationFrame frame) async {
    if (_closed || !_waves.isReady) {
      throw StateError('Ocean view inputs unavailable.');
    }
    _prepared = false;
    if (isMorphing) {
      for (final mesh in _meshes) {
        mesh.morphWeights = [frame.transitionFraction];
      }
    }
    final config = configuration, prefix = configuration.id;
    // Refresh against the live camera every frame, even between LOD rebuilds.
    // Bounds include both stitched morph endpoints, mean level and displacement.
    for (var i = 0; i < _fogBounds.length; i++) {
      final bounds = _fogBounds[i];
      _meshes[i].visible = config.fog!.intersectsVisibleRange(
        config.camera.position,
        bounds.center,
        bounds.radius,
      );
    }
    for (final entry in _caustics.entries) {
      await _measure(
        '$prefix.caustics.${entry.key}',
        entry.value.update,
        dispatches: () => entry.value.lastStats?.dispatches,
        draws: () => entry.value.lastStats?.drawCalls,
      );
    }
    if (config.underwater case final inputs?) {
      final sample = await inputs.sampleCamera(config.camera, frame);
      if (sample == null ||
          sample.seconds != frame.seconds ||
          sample.positionEcef != config.camera.position) {
        throw StateError('Camera water sample is unavailable or stale.');
      }
      int? draws;
      await _measure('$prefix.boundary', () async {
        draws = (await _boundary!.update(config.camera)).drawCalls;
      }, draws: () => draws);
      if (sample.positionEcef != config.camera.position) {
        throw StateError('Camera moved after its water sample.');
      }
      await _measure(
        '$prefix.underwater.prepare',
        () => _underwater!.prepare(
          camera: config.camera,
          viewport: config.size,
          signedSurfaceDistance: sample.signedDistanceMetres,
          surfaceUp: sample.upEcef,
        ),
      );
    }
    _prepared = true;
  }

  /// Synchronously replaces the prepared ocean contribution in an ECEF scene.
  /// Call after the controller operation and before rendering this fixed viewport.
  /// The host owns sample count and HDR configuration; they must match the recipe.
  void attach(Scene scene, {bool replaceConfiguration = false}) {
    if (!isReady || (_scene != null && !identical(_scene, scene))) {
      throw StateError(
        'Ocean view is unavailable or already attached elsewhere.',
      );
    }
    if (scene.renderSettings.sampleCount != configuration.sampleCount) {
      throw StateError(
        'Scene sample count differs from its ocean allocation plan.',
      );
    }
    _boundary?.checkCurrent(configuration.camera, configuration.size);
    final previous = _owners[scene];
    if (identical(previous, this)) return;
    if (previous != null &&
        !replaceConfiguration &&
        !identical(previous.configuration, configuration)) {
      throw StateError(
        'Replace a scene ocean with the same view configuration.',
      );
    }
    if (_underwaterVisible) {
      _underwater?.attach(scene);
    } else {
      previous?._underwater?.detach();
    }
    _originalScale =
        previous?._originalScale ?? scene.renderSettings.opaqueCaptureScale;
    if (previous != null) {
      scene.remove(previous.root);
      previous._scene = null;
    }
    scene.add(root);
    scene.renderSettings = quality.applyTo(scene.renderSettings);
    _scene = scene;
    _owners[scene] = this;
  }

  /// Applies independent visual layer switches. Surface visibility also hides its
  /// shaded foam; underwater remains independently selectable.
  Future<void> setVisibility({
    required bool surface,
    required bool foam,
    required bool underwater,
  }) async {
    if (_closed) throw StateError('Ocean view closed.');
    for (final water in _water) {
      await water.setFoamEnabled(foam);
    }
    root.visible = surface;
    _underwaterVisible = underwater;
    if (_scene case final scene?) {
      if (underwater) {
        _underwater?.attach(scene);
      } else {
        _underwater?.detach();
      }
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    if (_scene case final scene? when identical(_owners[scene], this)) {
      scene.remove(root);
      if (scene.renderSettings.opaqueCaptureScale == quality.sceneInputScale) {
        scene.renderSettings = scene.renderSettings.copyWith(
          opaqueCaptureScale: _originalScale,
        );
      }
      _owners[scene] = null;
    }
    _scene = null;
    final failures = <Object>[];
    for (final close in _cleanup.reversed) {
      try {
        await close();
      } catch (error) {
        failures.add(error);
      }
    }
    if (failures.isNotEmpty) throw ScopeCleanupException(failures);
  }
}
