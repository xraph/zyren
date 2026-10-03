import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/widgets.dart' as widgets;
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'tile_attribution_bar.dart';
import 'geospatial_presets.dart';
import 'geospatial_scene.dart';
import 'geospatial_device_profile.dart';
import 'preset_globe_controls.dart';
import 'zero_state.dart';
import 'rendering_choices.dart';
import 'render_telemetry.dart';
import 'photorealistic_layout.dart';

void main() => runApp(const GoogleTilesLabApp());

class GoogleTilesLabApp extends StatelessWidget {
  final GlobalKey<GoogleTilesLabState>? labKey;
  final bool clouds;
  final GoogleTilesPreset? initialPreset;
  final AssetServices assetServices;
  const GoogleTilesLabApp({
    super.key,
    this.labKey,
    this.initialPreset,
    this.assetServices = SceneRuntime.defaultAssetServices,
    this.clouds = const bool.fromEnvironment('ZYREN_LAB_CLOUDS'),
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: GoogleTilesLab(
      key: labKey,
      clouds: clouds,
      initialPreset: initialPreset,
      assetServices: assetServices,
    ),
  );
}

class GoogleTilesLab extends StatefulWidget {
  final bool clouds;
  final GoogleTilesPreset? initialPreset;
  final AssetServices assetServices;
  const GoogleTilesLab({
    super.key,
    this.clouds = false,
    this.initialPreset,
    this.assetServices = SceneRuntime.defaultAssetServices,
  });
  @override
  State<GoogleTilesLab> createState() => GoogleTilesLabState();
}

class GoogleTilesLabState extends State<GoogleTilesLab> {
  static const _googleKey = String.fromEnvironment('ZYREN_GOOGLE_MAPS_KEY');
  static const _ionToken = String.fromEnvironment('ZYREN_CESIUM_ION_TOKEN');
  static bool get configured => _googleKey.isNotEmpty || _ionToken.isNotEmpty;
  late final SceneController controller;
  late final GeospatialSceneProfile profile;
  late final GeospatialDeviceProfile deviceProfile;
  CloudQualitySelection _quality = CloudQualitySelection.auto;
  CloudQualitySelection _shadowQuality = CloudQualitySelection.auto;
  bool _shadowsEnabled = true;
  bool _qualityChanging = false, _initialized = false;
  (CloudQualitySelection, bool, CloudQualitySelection)? _failedQuality;
  StreamSubscription<FrameStats>? _qualityFrames;
  int? _refinement;
  RenderTelemetry? _telemetry;
  final _controls = PresetGlobeControlsPlugin();
  List<GoogleTilesPreset> get presets => widget.clouds
      ? GoogleTilesPreset.cloudPresets
      : GoogleTilesPreset.atmospherePresets;
  Tiles3DProviderSession? _provider;
  AssetScope? _manifest;
  Tiles3DPlugin? tiles;
  bool _loading = true;
  Object? _error;
  Future<void>? _loadTask, _closing;
  Future<void> get whenClosed => _closing ?? Future<void>.value();
  Object? get loadError => _error;
  GoogleTilesPreset _preset = GoogleTilesPreset.manhattan;
  GoogleTilesPreset get preset => _preset;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final view = View.of(context);
    deviceProfile = GeospatialDeviceProfile.forViewport(
      defaultTargetPlatform,
      view.physicalSize.shortestSide / view.devicePixelRatio,
    );
    final initial = widget.initialPreset ?? presets.first;
    if (!presets.contains(initial)) {
      throw ArgumentError('The initial preset must belong to this lab.');
    }
    controller =
        SceneController(
            scene: Scene()..background = const Color3(.035, .055, .08),
            camera: PerspectiveCamera(
              near: 1,
              far: 1e8,
              depthStrategy: DepthStrategy.reversed,
            ),
            options: const EngineOptions(
              presentation: PresentationPolicy.requireNative,
              recovery: RecoveryPolicy.automaticOnce,
            ),
            runtime: switch (defaultTargetPlatform) {
              TargetPlatform.android => SceneRuntime.nativeAndroid(
                assetServices: widget.assetServices,
                resourceBudgetBytes: deviceProfile.resourceBudgetBytes,
                sceneUploadBudgetBytes: deviceProfile.sceneUploadBudgetBytes,
              ),
              TargetPlatform.iOS ||
              TargetPlatform.macOS => SceneRuntime.nativeMetal(
                assetServices: widget.assetServices,
                resourceBudgetBytes: deviceProfile.resourceBudgetBytes,
                sceneUploadBudgetBytes: deviceProfile.sceneUploadBudgetBytes,
              ),
              _ => SceneRuntime(
                assetServices: widget.assetServices,
                sceneUploadBudgetBytes: deviceProfile.sceneUploadBudgetBytes,
              ),
            },
          )
          ..use(GeospatialPlugin())
          ..use(_controls);
    profile = GeospatialSceneProfile(
      services: controller.runtime.assetServices,
      clouds: widget.clouds,
      preset: initial,
      cloudQuality: deviceProfile.clouds(),
    );
    for (final plugin in profile.plugins) {
      controller.use(plugin);
    }
    if (const bool.fromEnvironment('ZYREN_RENDER_TELEMETRY')) {
      _telemetry = RenderTelemetry(controller, () async {
        final stats = tiles?.stats;
        final cloud = profile.cloudLayer?.controller;
        return {
          'preset': _preset.name,
          'status': controller.status.value.runtimeType.toString(),
          'issueCode': switch (controller.status.value) {
            SceneFailed(:final issue) => issue.code,
            _ => null,
          },
          'moonlight': profile.moonlight.name,
          'night': profile.nightView,
          'camera': controller.camera.position.storage,
          'target': controller.camera.target.storage,
          'cloudSize': cloud == null ? null : [cloud.width, cloud.height],
          'cloudFrames': cloud?.history.accumulatedFrames,
          'cloudPreset': cloud?.quality.name,
          'animation': profile.cloudAnimationEnabled,
          'density': profile.cloudDensity,
          'sparsity': profile.cloudSparsity,
          'effectiveCoverage': cloud?.parameters.effectiveCoverage,
          'visibleTiles': stats?.visibleTiles,
          'selectedTiles': stats?.selectedTiles,
          'loadingTiles': stats?.activeRequests,
          'decodedTileBytes': stats?.cachedBytes,
          'tilePayloadBytes': stats?.residentBytes,
          'budgetLimited': stats?.budgetLimited,
          'prefetchedTiles': stats?.prefetchedTiles,
          'prefetchBytes': stats?.prefetchBytes,
          'displayedTiles': stats?.displayedTiles,
          'effectiveTileScreenError': stats?.effectiveScreenError,
          'failedTiles': tiles?.failures.length,
          'tileFailureCodes': {
            for (final code in AssetLoadError.values)
              if (tiles?.failures.any((failure) => failure.code == code) ??
                  false)
                code.name: tiles!.failures
                    .where((failure) => failure.code == code)
                    .length,
          },
        };
      });
    }
    if (widget.clouds) {
      _qualityFrames = controller.frameStats.listen((_) {
        final count = math.min(
          16,
          profile.cloudLayer!.controller.history.accumulatedFrames,
        );
        if (mounted && count != _refinement) {
          setState(() => _refinement = count);
        }
      });
    }
    _view(initial);
    unawaited(_startLoad());
  }

  Future<void> _setQuality(
    CloudQualitySelection selection, {
    bool? shadowsEnabled,
    CloudQualitySelection? shadowQuality,
  }) async {
    if (_qualityChanging) return;
    final shadows = shadowsEnabled ?? _shadowsEnabled;
    final shadow = shadowQuality ?? _shadowQuality;
    setState(() {
      _qualityChanging = true;
      _failedQuality = null;
    });
    try {
      await profile.setCloudQuality(
        deviceProfile.clouds(selection.preset, shadows, shadow.preset),
      );
      if (mounted) {
        setState(() {
          _quality = selection;
          _shadowsEnabled = shadows;
          _shadowQuality = shadow;
          if (_refinement != null) {
            _refinement = math.min(
              16,
              profile.cloudLayer!.controller.history.accumulatedFrames,
            );
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _failedQuality = (selection, shadows, shadow));
      }
    } finally {
      if (mounted) setState(() => _qualityChanging = false);
    }
  }

  void _view(GoogleTilesPreset preset) {
    _preset = preset;
    _refinement = null;
    _controls.controls?.cancel();
    profile.apply(controller.scene, controller.camera, preset);
    _controls.resetForPreset();
    controller.invalidate();
  }

  Future<void> _startLoad() => _loadTask = _load();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    if (!configured) {
      setState(() => _loading = false);
      return;
    }
    Tiles3DProviderSession? provider;
    AssetScope? manifest;
    try {
      final base = controller.runtime.assetServices;
      provider = _googleKey.isNotEmpty
          ? await Tiles3DProvider.googleMaps(
              transport: base.resolver,
              apiKey: () => _googleKey,
            )
          : await Tiles3DProvider.cesiumIon(
              transport: base.resolver,
              accessToken: () => _ionToken,
              assetId: 2275207,
            );
      if (!mounted) return;
      final services = AssetServices(
        resolver: provider,
        imageDecoder: base.imageDecoder,
        textureDecoder: base.textureDecoder,
        bufferDecoder: base.bufferDecoder,
        meshDecoder: base.meshDecoder,
      );
      manifest = AssetScope(services: services);
      _provider = provider;
      _manifest = manifest;
      final tileset = await manifest
          .load(Tiles3D.tileset(provider.rootUri))
          .result;
      if (!mounted) return;
      tiles = Tiles3DPlugin(
        motionPolicy: const Tiles3DMotionPolicy(),
        visibilityPolicy: (bounds, camera) => const EllipsoidHorizon()
            .isSphereVisible(camera.position, bounds.center, bounds.radius),
        tileset: tileset,
        services: services,
        maximumScreenError: 8,
        budget: Tiles3DBudget(
          maxRequests: deviceProfile.tileRequests,
          maxPrefetchRequests: 1,
          maxPrefetchBytes: 16 * 1024 * 1024,
          maxSelectedTiles: deviceProfile.selectedTiles,
          maxDecodedBytes: deviceProfile.decodedTileBytes,
          maxResidentBytes: deviceProfile.tileBytes,
          perTileDecodedBytes: 16 * 1024 * 1024,
          perTileResidentBytes: 8 * 1024 * 1024,
        ),
        onChanged: (_) {
          if (mounted) setState(() {});
        },
      );
      controller.use(tiles!);
      _provider = provider;
      _manifest = manifest;
      provider = null;
      manifest = null;
    } catch (error) {
      if (mounted) _error = error;
    } finally {
      if (manifest != null && identical(_manifest, manifest)) _manifest = null;
      if (provider != null && identical(_provider, provider)) _provider = null;
      await manifest?.close();
      await provider?.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    unawaited(_telemetry?.close());
    unawaited(_qualityFrames?.cancel());
    controller.dispose();
    _closing = _close();
    unawaited(_closing);
    super.dispose();
  }

  Future<void> _close() async {
    await controller.whenDisposed;
    await _manifest?.close();
    await _provider?.close();
    await _loadTask;
  }

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    ),
  );

  Widget _cloudSlider({
    required String name,
    required String hint,
    required double value,
    required ValueChanged<double> onChanged,
  }) => Tooltip(
    message: hint,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$name ${(value * 100).round()}%'),
        Slider(
          key: ValueKey('cloud-${name.toLowerCase()}'),
          value: value,
          divisions: 20,
          label: '${(value * 100).round()}%',
          semanticFormatterCallback: (value) =>
              '${(value * 100).round()} percent cloud ${name.toLowerCase()}',
          onChanged: (value) => setState(() {
            onChanged(value);
            _refinement = null;
          }),
        ),
      ],
    ),
  );

  Widget _controlsPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _section('Location', [
        Wrap(
          spacing: 6,
          children: [
            for (final preset in presets)
              ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.standard,
                label: Text(preset.label),
                selected: _preset == preset,
                onSelected: _loading
                    ? null
                    : (_) => setState(() => _view(preset)),
              ),
          ],
        ),
      ]),
      _section('Lighting', [
        Tooltip(
          message:
              'Natural follows lunar brightness. Visible adds night fill when the Moon is down.',
          child: RenderingChoices<MoonlightSelection>(
            key: const ValueKey('moonlight'),
            label: 'Moonlight',
            selected: profile.moonlight,
            choices: MoonlightSelection.values,
            choiceLabel: (choice) => choice.label,
            onChanged: (value) => setState(() => profile.moonlight = value),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilterChip(
            showCheckmark: false,
            visualDensity: VisualDensity.standard,
            key: const ValueKey('night-view'),
            label: const Text('Night view'),
            selected: profile.nightView,
            onSelected: (value) => setState(() {
              profile.nightView = value;
              _refinement = null;
            }),
          ),
        ),
      ]),
      if (widget.clouds)
        _section('Clouds', [
          Tooltip(
            message: 'Cloud sampling quality. Auto uses your device profile.',
            child: RenderingChoices<CloudQualitySelection>(
              key: const ValueKey('cloud-quality'),
              label: 'Quality',
              selected: _quality,
              choices: CloudQualitySelection.values,
              choiceLabel: (choice) => choice.label,
              onChanged: _qualityChanging
                  ? null
                  : (value) => unawaited(_setQuality(value)),
            ),
          ),
          _cloudSlider(
            name: 'Density',
            hint: 'Thin all cloud layers without changing coverage.',
            value: profile.cloudDensity,
            onChanged: (value) => profile.cloudDensity = value,
          ),
          _cloudSlider(
            name: 'Sparsity',
            hint:
                'Reduce cloud coverage. 0% keeps the location preset; 100% clears the cloud layers.',
            value: profile.cloudSparsity,
            onChanged: (value) => profile.cloudSparsity = value,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              showCheckmark: false,
              visualDensity: VisualDensity.standard,
              key: const ValueKey('cloud-animation'),
              label: const Text('Animate clouds'),
              selected: profile.cloudAnimationEnabled,
              onSelected: (value) => setState(() {
                profile.cloudAnimationEnabled = value;
                _refinement = null;
              }),
            ),
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_qualityChanging)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (_refinement case final frames?)
                Text(frames < 16 ? 'Refining clouds…' : 'Clouds refined'),
            ],
          ),
        ]),
      if (widget.clouds)
        _section('Shadows', [
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              showCheckmark: false,
              visualDensity: VisualDensity.standard,
              key: const ValueKey('cloud-shadows'),
              label: const Text('Cloud shadows'),
              selected: _shadowsEnabled,
              onSelected: _qualityChanging
                  ? null
                  : (value) =>
                        unawaited(_setQuality(_quality, shadowsEnabled: value)),
            ),
          ),
          Tooltip(
            message: 'Shadow quality. Auto follows cloud quality.',
            child: RenderingChoices<CloudQualitySelection>(
              key: const ValueKey('cloud-shadow-quality'),
              label: 'Quality',
              selected: _shadowQuality,
              choices: CloudQualitySelection.values,
              choiceLabel: (choice) => choice.label,
              onChanged: _qualityChanging || !_shadowsEnabled
                  ? null
                  : (value) =>
                        unawaited(_setQuality(_quality, shadowQuality: value)),
            ),
          ),
        ]),
      if (_failedQuality case final selection?) ...[
        const Text('Cloud quality could not change.'),
        TextButton(
          onPressed: () => unawaited(
            _setQuality(
              selection.$1,
              shadowsEnabled: selection.$2,
              shadowQuality: selection.$3,
            ),
          ),
          child: const Text('Retry quality'),
        ),
      ],
    ],
  );

  Widget _infoPanel() {
    final stats = tiles?.stats;
    final failures = tiles?.failures ?? const <TileFailure3D>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('Tiles', [
          Text(
            _loading
                ? 'Connecting to tiles…'
                : !configured
                ? 'Provider access is not configured.'
                : _error != null
                ? 'Provider connection failed.'
                : '${stats?.visibleTiles ?? 0} tiles · ${stats?.activeRequests ?? 0} loading',
          ),
          if (stats?.budgetLimited ?? false)
            const Text('Detail limited by tile budget'),
          if (failures.isNotEmpty) ...[
            Text(
              '${failures.length} tiles unavailable',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: tiles!.retryFailed,
                child: const Text('Retry tiles'),
              ),
            ),
          ],
        ]),
        if (widget.clouds)
          _section('Rendering', [
            Text(
              '${deviceProfile.device.name} · ${profile.cloudQuality.preset.name} clouds',
            ),
          ]),
        _section('Data sources', [
          if (_provider case final provider?)
            TileAttributionBar(
              expanded: true,
              googleMaps: provider.isGoogleMaps,
              tileCredits: tiles?.attributions ?? const [],
              providerCredits: provider.attributions,
            )
          else
            const Text('Source credits appear when the provider connects.'),
        ]),
      ],
    );
  }

  Widget _scene() => _loading
      ? const Center(child: CircularProgressIndicator())
      : !configured
      ? widgets.ZeroState(
          title: 'Google Maps access is required',
          message:
              'Add Google Maps or Cesium Ion access to the build configuration.',
          actionLabel: 'Check access',
          onAction: _startLoad,
        )
      : _error != null
      ? widgets.ZeroState(
          title: 'Google Maps could not load',
          message: 'Check provider access and your network connection.',
          actionLabel: 'Retry connection',
          onAction: _startLoad,
        )
      : LayoutBuilder(
          builder: (context, bounds) {
            final ratio = MediaQuery.devicePixelRatioOf(context);
            final scale = geospatialResolutionScale(
              width: math.max(1.0, bounds.maxWidth * ratio),
              height: math.max(1.0, bounds.maxHeight * ratio),
              maxDimension: deviceProfile.maxDimension,
              maxPixels: deviceProfile.maxPixels,
            );
            return SceneView(
              controller: controller,
              resolutionScale: math.min(1, scale),
              errorBuilder: (context, issue, retry) =>
                  RendererZeroState(error: issue, onRetry: retry),
            );
          },
        );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: PhotorealisticLayout(
        scene: _scene(),
        controls: _controlsPanel(),
        info: _infoPanel(),
        controlsNeedAttention: _failedQuality != null,
        infoNeedsAttention:
            _error != null || (tiles?.failures.isNotEmpty ?? false),
        attribution: _provider == null
            ? null
            : TileAttributionBar(
                googleMaps: _provider!.isGoogleMaps,
                tileCredits: tiles?.attributions ?? const [],
                providerCredits: _provider!.attributions,
                showSourcesButton: false,
              ),
      ),
    ),
  );
}
