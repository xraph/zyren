import 'package:flutter/material.dart';
import 'scene_launcher.dart';
export 'planet_page.dart' show PlanetPage;

void main() => runApp(const PlanetApp());

class PlanetApp extends StatelessWidget {
  final Widget home;
  const PlanetApp({super.key, this.home = const GeospatialSceneLauncher()});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zyren geospatial',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: const Color(0xff080e19),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff78dace),
        brightness: Brightness.dark,
      ),
    ),
    home: home,
  );
}
