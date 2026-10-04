import 'package:flutter/material.dart';
import 'package:flutter_zyren/widgets.dart';
import 'atmosphere_lab.dart';
import 'camera_lab.dart';
import 'google_tiles_lab.dart';
import 'layers/layers_lab.dart';
import 'layers/offline.dart';
import 'ocean/ocean_page.dart';
import 'planet_page.dart';
import 'terrain_lab.dart';
import 'tiles3d_lab.dart';

class GeospatialDemo {
  final String id, title, description, category;
  final IconData icon;
  final bool requiresProvider;
  final WidgetBuilder build;
  const GeospatialDemo(
    this.id,
    this.title,
    this.description,
    this.category,
    this.icon,
    this.build, {
    this.requiresProvider = false,
  });
}

final geospatialDemos = <GeospatialDemo>[
  GeospatialDemo(
    'photorealistic',
    'Photorealistic Earth',
    'Stream cities with atmosphere and globe navigation.',
    'Earth',
    Icons.public,
    (_) => const GoogleTilesLab(),
    requiresProvider: true,
  ),
  GeospatialDemo(
    'clouds',
    'Earth with clouds',
    'Cloud layers, shadows and light shafts over streamed cities.',
    'Earth',
    Icons.cloud_outlined,
    (_) => const GoogleTilesLab(clouds: true),
    requiresProvider: true,
  ),
  for (final scene in const [
    (
      'earth',
      'Monterey Bay',
      'Offline NOAA coastline, terrain and bathymetry.',
    ),
    ('calm', 'Open water', 'Long swells in clear daylight.'),
    ('storm', 'Storm swell', 'Wind-driven waves and reflections.'),
    (
      'coast',
      'Shallow coast',
      'A saved synthetic coast with foam and shallow water.',
    ),
    ('vessel', 'Buoyant vessel', 'A hull driven by physical water samples.'),
    (
      'underwater',
      'Below the surface',
      'Water transport, light shafts and caustics.',
    ),
    (
      'orbit',
      'Orbit to surface',
      'Fly from the whole globe down to the water.',
    ),
  ])
    GeospatialDemo(
      'ocean.${scene.$1}',
      scene.$2,
      scene.$3,
      'Ocean',
      Icons.waves,
      (_) => OceanLabPage(initialScene: scene.$1),
    ),
  GeospatialDemo(
    'layers',
    'Layers',
    'Visibility, ordering and saved layer state.',
    'World tools',
    Icons.layers_outlined,
    (_) => const LayersLab(),
  ),
  GeospatialDemo(
    'offline',
    'Offline regions',
    'Download, verify and reopen owned region fixtures.',
    'World tools',
    Icons.offline_pin_outlined,
    (_) => const OfflineLab(),
  ),
  GeospatialDemo(
    'terrain',
    'Terrain streaming',
    'Explore tile detail and recover failed loads.',
    'World tools',
    Icons.terrain_outlined,
    (_) => const TerrainLab(),
  ),
  GeospatialDemo(
    'tiles',
    '3D Tiles',
    'Local tiles, refinement and resource limits.',
    'World tools',
    Icons.location_city,
    (_) => const Tiles3DLab(),
  ),
  GeospatialDemo(
    'atmosphere',
    'Atmosphere',
    'Inspect the sky and aerial perspective.',
    'World tools',
    Icons.wb_twilight,
    (_) => const AtmosphereLab(),
  ),
  GeospatialDemo(
    'camera',
    'Camera poses',
    'Inspect saved camera positions and transitions.',
    'World tools',
    Icons.videocam_outlined,
    (_) => const CameraLab(),
  ),
  GeospatialDemo(
    'globe',
    'Globe markers',
    'Navigate an ellipsoid and geodetic city markers.',
    'World tools',
    Icons.language,
    (_) => const PlanetPage(),
  ),
];

/// One app entry point. A native scene is created only when you open it.
class GeospatialSceneLauncher extends StatefulWidget {
  final Widget Function(GeospatialDemo)? sceneBuilder;
  const GeospatialSceneLauncher({super.key, this.sceneBuilder});
  @override
  State<GeospatialSceneLauncher> createState() =>
      _GeospatialSceneLauncherState();
}

class _GeospatialSceneLauncherState extends State<GeospatialSceneLauncher> {
  String _filter = 'All';
  bool _opening = false;
  Object? _failure;
  Future<void> _open(GeospatialDemo demo) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _failure = null;
    });
    final oceanKey = GlobalKey<OceanLabPageState>();
    try {
      var page = widget.sceneBuilder?.call(demo) ?? demo.build(context);
      if (page is OceanLabPage) {
        page = OceanLabPage(
          key: oceanKey,
          initialScene: page.initialScene,
          storageDirectory: page.storageDirectory,
        );
      }
      final route = MaterialPageRoute<void>(
        settings: RouteSettings(name: '/scene/${demo.id}'),
        builder: (context) => page,
      );
      await Navigator.of(context).push(route);
      final oceanState = oceanKey.currentState;
      await route.completed;
      await oceanState?.whenClosed;
    } catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scenes = geospatialDemos
        .where((s) => _filter == 'All' || s.category == _filter)
        .toList();
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Geospatial scenes',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${geospatialDemos.length} demos',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    for (final category in const [
                      'All',
                      'Earth',
                      'Ocean',
                      'World tools',
                    ])
                      ChoiceChip(
                        label: Text(category),
                        selected: _filter == category,
                        onSelected: _opening
                            ? null
                            : (_) => setState(() => _filter = category),
                      ),
                  ],
                ),
              ),
            ),
            if (_failure != null)
              SliverToBoxAdapter(
                child: ZeroState(
                  title: 'Scene could not open',
                  message: '$_failure',
                  actionLabel: 'Dismiss',
                  onAction: () => setState(() => _failure = null),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              sliver: SliverList.separated(
                itemCount: scenes.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final scene = scenes[index];
                  return ListTile(
                    key: ValueKey('scene-${scene.id}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    leading: Icon(
                      scene.icon,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(scene.title),
                    subtitle: Text(
                      scene.description +
                          (scene.requiresProvider
                              ? ' Provider access required.'
                              : ''),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: !_opening,
                    onTap: () => _open(scene),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
