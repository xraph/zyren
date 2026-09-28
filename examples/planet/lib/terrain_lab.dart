import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'zero_state.dart';

void main() => runApp(const TerrainLabApp());

class TerrainFixture {
  VoidCallback? onChanged;
  static const origin = Vec3(6378137, 0, 0);
  final scene = Scene()
    ..background = const Color3(.035, .055, .08)
    ..lightDirection = const Vec3(1, -.4, .8)
    ..ambient = .35;
  final camera = PerspectiveCamera(
    position: origin + const Vec3(12000, 0, 0),
    target: origin,
    up: const Vec3(0, 0, 1),
    near: 10,
    far: 30000,
  );
  _LabSource _source = _LabSource();
  late final terrain = TerrainPlugin(
    source: _source,
    onChanged: (_) => onChanged?.call(),
    budget: TileBudget(
      maxRequests: 3,
      maxDecodedBytes: 2 * 1024 * 1024,
      maxResidentBytes: 2 * 1024 * 1024,
    ),
  );
  void view(String view) {
    camera.target = origin;
    camera.position =
        origin +
        switch (view) {
          'Detail' => const Vec3(1800, -800, 400),
          'East' => const Vec3(1400, 1500, 800),
          'West' => const Vec3(1400, -1500, 800),
          _ => const Vec3(12000, 0, 0),
        };
  }

  bool get offline => _source.offline;
  void setOffline(bool value) {
    _source = _LabSource()..offline = value;
    terrain.replaceSource(_source);
  }

  void reconnect() {
    _source.offline = false;
    terrain.retryFailed();
  }
}

class _LabSource implements TerrainSource {
  final base = ProceduralTerrainSource(
    latency: const Duration(milliseconds: 70),
  );
  bool offline = false;
  @override
  Ellipsoid get ellipsoid => base.ellipsoid;
  @override
  String get identity => '${base.identity}:lab';
  @override
  Iterable<TileCoordinate> get roots => base.roots;
  @override
  TileMetadata describe(TileCoordinate coordinate) => base.describe(coordinate);
  @override
  Future<TerrainTile> load(
    TileCoordinate coordinate,
    TileLoadContext context,
  ) async {
    if (offline && coordinate.z > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 70));
      context.cancellation.throwIfCancelled();
      throw StateError('Simulated offline source');
    }
    return base.load(
      coordinate,
      TileLoadContext(
        sourceIdentity: base.identity,
        cancellation: context.cancellation,
        byteBudget: context.byteBudget,
      ),
    );
  }
}

SceneController terrainLabController(TerrainFixture fixture) =>
    SceneController(
        scene: fixture.scene,
        camera: fixture.camera,
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
        runtime: defaultTargetPlatform == TargetPlatform.android
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      )
      ..use(GeospatialPlugin())
      ..use(
        OrbitControlsPlugin(
          configure: (controls) {
            controls.minDistance = 500;
            controls.maxDistance = 20000;
            controls.enableDamping = true;
          },
        ),
      )
      ..use(fixture.terrain);

class TerrainLabApp extends StatelessWidget {
  final TerrainFixture? fixture;
  const TerrainLabApp({super.key, this.fixture});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: TerrainLab(fixture: fixture),
  );
}

class TerrainLab extends StatefulWidget {
  final TerrainFixture? fixture;
  const TerrainLab({super.key, this.fixture});
  @override
  State<TerrainLab> createState() => _TerrainLabState();
}

class _TerrainLabState extends State<TerrainLab> {
  late final fixture = widget.fixture ?? TerrainFixture();
  late final controller = terrainLabController(fixture);
  @override
  void initState() {
    super.initState();
    fixture.onChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    fixture.onChanged = null;
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = fixture.terrain.stats;
    final failures = fixture.terrain.failures;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ValueListenableBuilder<SceneStatus>(
                valueListenable: controller.status,
                builder: (context, status, _) {
                  final ready = status is SceneReady;
                  return Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'Terrain',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      for (final view in ['Overview', 'Detail', 'East', 'West'])
                        TextButton(
                          onPressed: !ready
                              ? null
                              : () {
                                  fixture.view(view);
                                  controller.invalidate();
                                },
                          child: Text(view),
                        ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Offline test'),
                          Switch(
                            value: fixture.offline,
                            onChanged: !ready
                                ? null
                                : (value) {
                                    setState(() => fixture.setOffline(value));
                                    controller.invalidate();
                                  },
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
            if (failures.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${failures.length} tiles unavailable; parent terrain remains visible',
                      style: const TextStyle(color: Colors.amber, fontSize: 12),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(fixture.reconnect);
                        controller.invalidate();
                      },
                      child: const Text('Reconnect and retry'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: SceneView(
                controller: controller,
                resolutionScale: math.min(
                  1,
                  1 / MediaQuery.devicePixelRatioOf(context),
                ),
                errorBuilder: (context, issue, retry) =>
                    ZeroState(error: issue, onRetry: retry),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                spacing: 12,
                children: [
                  Text(
                    '${stats?.visibleTiles ?? 0} tiles · ${stats?.activeRequests ?? 0} loading',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    '${((stats?.cachedBytes ?? 0) / 1024).round()} KiB cached · '
                    '${((stats?.residentBytes ?? 0) / 1024).round()} KiB visible',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const Text(
                    'Offline fixture · Drag to orbit · Scroll or pinch to zoom',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
