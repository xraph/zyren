import 'dart:convert';
import 'dart:io';
import 'package:planet/ocean/scenes/earth_coast.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

Future<void> main(List<String> args) => HttpOverrides.runZoned(() async {
  final coast = await OceanEarthCoast.open(
    Directory(args[0]),
    manifest: await File(args[1]).readAsString(),
  );
  try {
    var resources = 0;
    for (final name in OceanEarthCoast.names) {
      await coast.read(name);
      resources++;
    }
    final instant = GeoInstant(tick: 0, hz: 60, epoch: DateTime.utc(2026));
    print(
      jsonEncode({
        'revision': coast.dataRevision,
        'resources': resources,
        'water': (await coast.coverage.sample(coast.origin, instant)).value,
        'land': (await coast.coverage.sample(
          Geodetic.degrees(-121.85, 36.59),
          instant,
        )).value,
        'fetches': coast.fetches,
      }),
    );
  } finally {
    await coast.close();
  }
}, createHttpClient: (_) => throw StateError('Network access is forbidden.'));
