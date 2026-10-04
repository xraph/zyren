import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/widgets.dart' as widgets;
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'tiles3d_fixture.dart';
import 'tile_attribution_bar.dart';
import 'zero_state.dart';
import 'photorealistic_layout.dart';

void main() => runApp(const Tiles3DLabApp());

class Tiles3DLabApp extends StatelessWidget {
  final GlobalKey<Tiles3DLabState>? labKey;
  const Tiles3DLabApp({super.key, this.labKey});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: Tiles3DLab(key: labKey),
  );
}

class Tiles3DLab extends StatefulWidget {
  const Tiles3DLab({super.key});
  @override
  State<Tiles3DLab> createState() => Tiles3DLabState();
}

class Tiles3DLabState extends State<Tiles3DLab> {
  static const origin = Vec3(6378137, 0, 0);
  final camera = PerspectiveCamera(
    position: origin + const Vec3(1500, -900, 900),
    target: origin,
    up: const Vec3(1, 0, 0),
    near: .1,
    far: 1e9,
    depthStrategy: DepthStrategy.reversed,
  );
  late final controller =
      SceneController(
        scene: Scene()
          ..background = const Color3(.035, .055, .08)
          ..add(
            DirectionalLight(direction: const Vec3(-1, .4, -.8), intensity: 3),
          )
          ..add(HemisphereLight(up: const Vec3(1, 0, 0), intensity: .3)),
        camera: camera,
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
        runtime: defaultTargetPlatform == TargetPlatform.android
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      )..use(
        OrbitControlsPlugin(
          configure: (controls) {
            controls.minDistance = 30;
            controls.maxDistance = 1e8;
            controls.enableDamping = true;
          },
        ),
      );
  Tiles3DFixture? _fixture;
  Tileset3D? _tileset;
  Tiles3DPlugin? tiles;
  bool _loading = true;
  Object? _error;
  Object? get loadError => _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fixture =
          _fixture ?? await Tiles3DFixture.start(implicitTiling: true);
      if (!mounted) {
        await fixture.close();
        return;
      }
      _fixture = fixture;
      final tileset = await controller.assets
          .load(Tiles3D.tileset(fixture.uri))
          .result;
      if (!mounted) return;
      _tileset = tileset;
      tiles = Tiles3DPlugin(
        tileset: tileset,
        services: controller.runtime.assetServices,
        maximumScreenError: 24,
        onChanged: (_) {
          if (mounted) setState(() {});
        },
      );
      controller.use(tiles!);
    } catch (error) {
      if (mounted) _error = error;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _view(bool detail) {
    camera.target = origin;
    camera.position =
        origin +
        (detail ? const Vec3(450, -450, 350) : const Vec3(1500, -900, 900));
    controller.invalidate();
  }

  @override
  void dispose() {
    controller.dispose();
    final fixture = _fixture;
    if (fixture != null) unawaited(fixture.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = tiles?.stats;
    final failures = tiles?.failures ?? [];
    return Scaffold(
      body: SafeArea(
        child: PhotorealisticLayout(
          title: '3D Tiles',
          scene: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? widgets.ZeroState(
                  title: 'The tileset could not load',
                  message: '$_error',
                  actionLabel: 'Retry tileset',
                  onAction: _load,
                )
              : SceneView(
                  controller: controller,
                  errorBuilder: (context, issue, retry) =>
                      RendererZeroState(error: issue, onRetry: retry),
                ),
          controls: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<SceneStatus>(
                valueListenable: controller.status,
                builder: (context, status, _) {
                  final ready = status is SceneReady;
                  return Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        onPressed: ready ? () => _view(false) : null,
                        child: const Text('Overview'),
                      ),
                      TextButton(
                        onPressed: ready ? () => _view(true) : null,
                        child: const Text('Detail'),
                      ),
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('Fail downloads'),
                          Switch(
                            value: _fixture?.failChildren ?? false,
                            onChanged: ready
                                ? (value) {
                                    setState(
                                      () => _fixture!.failChildren = value,
                                    );
                                    tiles!.replaceTileset(_tileset!);
                                  }
                                : null,
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              if (failures.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${failures.length} tiles unavailable; parent remains visible',
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() => _fixture!.failChildren = false);
                          tiles!.retryFailed();
                        },
                        child: const Text('Reconnect and retry'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          info: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 12,
                children: [
                  Text(
                    '${stats?.visibleTiles ?? 0} tiles · ${stats?.activeRequests ?? 0} loading',
                  ),
                  const Text(
                    'Synthetic buildings · loopback HTTP',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
          controlsNeedAttention: failures.isNotEmpty,
          attribution: TileAttributionBar(
            tileCredits: tiles?.attributions ?? const [],
          ),
        ),
      ),
    );
  }
}
