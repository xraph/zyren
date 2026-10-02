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
import 'preset_globe_controls.dart';
import 'zero_state.dart';

void main() => runApp(const GoogleTilesLabApp());

class GoogleTilesLabApp extends StatelessWidget {
  final GlobalKey<GoogleTilesLabState>? labKey;
  final bool clouds;
  const GoogleTilesLabApp({
    super.key,
    this.labKey,
    this.clouds = const bool.fromEnvironment('ZYREN_LAB_CLOUDS'),
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: GoogleTilesLab(key: labKey, clouds: clouds),
  );
}

class GoogleTilesLab extends StatefulWidget {
  final bool clouds;
  const GoogleTilesLab({super.key, this.clouds = false});
  @override
  State<GoogleTilesLab> createState() => GoogleTilesLabState();
}

class GoogleTilesLabState extends State<GoogleTilesLab> {
  static const _googleKey = String.fromEnvironment('ZYREN_GOOGLE_MAPS_KEY');
  static const _ionToken = String.fromEnvironment('ZYREN_CESIUM_ION_TOKEN');
  static bool get configured => _googleKey.isNotEmpty || _ionToken.isNotEmpty;
  late final SceneController controller;
  late final GeospatialSceneProfile profile;
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
  void initState() {
    super.initState();
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
            ),
            runtime: switch (defaultTargetPlatform) {
              TargetPlatform.android => const SceneRuntime.nativeAndroid(),
              TargetPlatform.iOS ||
              TargetPlatform.macOS => const SceneRuntime.nativeMetal(),
              _ => const SceneRuntime(),
            },
          )
          ..use(GeospatialPlugin())
          ..use(_controls);
    profile = GeospatialSceneProfile(
      services: controller.runtime.assetServices,
      clouds: widget.clouds,
    );
    for (final plugin in profile.plugins) {
      controller.use(plugin);
    }
    _view(presets.first);
    unawaited(_startLoad());
  }

  void _view(GoogleTilesPreset preset) {
    _preset = preset;
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
        fadeDuration: const Duration(milliseconds: 250),
        tileset: tileset,
        services: services,
        maximumScreenError: 20,
        budget: Tiles3DBudget(
          maxRequests: 2,
          maxSelectedTiles: 512,
          maxDecodedBytes: 512 * 1024 * 1024,
          maxResidentBytes: (widget.clouds ? 16 : 32) * 1024 * 1024,
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

  @override
  Widget build(BuildContext context) {
    final stats = tiles?.stats;
    final failures = tiles?.failures ?? const <TileFailure3D>[];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Photorealistic 3D',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  for (final preset in presets)
                    ChoiceChip(
                      label: Text(preset.label),
                      selected: _preset == preset,
                      onSelected: _loading
                          ? null
                          : (_) => setState(() => _view(preset)),
                    ),
                ],
              ),
            ),
            if (failures.isNotEmpty)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${failures.length} tiles unavailable',
                    style: const TextStyle(color: Colors.amber),
                  ),
                  TextButton(
                    onPressed: tiles!.retryFailed,
                    child: const Text('Retry tiles'),
                  ),
                ],
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : !configured
                  ? widgets.ZeroState(
                      title: 'Google Maps access is required',
                      message:
                          'Configure ZYREN_GOOGLE_MAPS_KEY or ZYREN_CESIUM_ION_TOKEN when you build this lab.',
                      actionLabel: 'Check access',
                      onAction: _startLoad,
                    )
                  : _error != null
                  ? widgets.ZeroState(
                      title: 'Google Maps could not load',
                      message:
                          'Check provider access and your network connection.',
                      actionLabel: 'Retry connection',
                      onAction: _startLoad,
                    )
                  : LayoutBuilder(
                      builder: (context, bounds) {
                        final longest =
                            math.max(bounds.maxWidth, bounds.maxHeight) *
                            MediaQuery.devicePixelRatioOf(context);
                        return SceneView(
                          controller: controller,
                          resolutionScale: math.min(
                            1,
                            640 / math.max(1, longest),
                          ),
                          errorBuilder: (context, issue, retry) =>
                              ZeroState(error: issue, onRetry: retry),
                        );
                      },
                    ),
            ),
            if (_provider case final provider?)
              TileAttributionBar(
                googleMaps: provider.isGoogleMaps,
                tileCredits: tiles?.attributions ?? const [],
                providerCredits: provider.attributions,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                spacing: 12,
                children: [
                  Text(
                    '${stats?.visibleTiles ?? 0} tiles · ${stats?.activeRequests ?? 0} loading',
                  ),
                  if (stats?.budgetLimited ?? false)
                    const Text('Detail limited by memory budget'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
