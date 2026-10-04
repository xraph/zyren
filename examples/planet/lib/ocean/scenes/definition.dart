import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

final class OceanLabSceneDefinition {
  final String id, name, revision;
  final int seed;
  final double wind, amplitude, patchMetres, choppiness;
  final Vec3 cameraLocal, targetLocal;
  final DateTime epoch;
  final double meanLevel;
  OceanLabSceneDefinition._(
    this.id,
    this.name,
    this.revision,
    this.seed,
    this.wind,
    this.amplitude,
    this.patchMetres,
    this.choppiness,
    this.cameraLocal,
    this.targetLocal,
    this.epoch, [
    this.meanLevel = 0,
  ]);
  bool get hasUnderwater => id == 'underwater' || id == 'coast';
  bool get hasVessel => id == 'vessel';
  bool get hasCoast => id == 'coast' || id == 'earth';
  static OceanLabSceneDefinition monterey(double meanLevel) =>
      OceanLabSceneDefinition._(
        'earth',
        'Monterey Bay',
        'noaa-etopo2022-monterey-1',
        44,
        8,
        .001,
        64,
        .4,
        const Vec3(-2500, 2000, 1600),
        const Vec3(1000, -3500, 0),
        DateTime.utc(2026, 10, 4, 8),
        meanLevel,
      );
  OceanSeaState get sea => OceanSeaState(
    seed: seed,
    canonicalResolution: 128,
    meanLevel: meanLevel,
    bands: [
      OceanWaveBand(
        patchMetres: patchMetres,
        minWaveNumber: 0,
        maxWaveNumber: 1,
        windSpeed: wind,
        windHeadingRadians: .35,
        amplitude: amplitude,
        choppiness: choppiness,
        depthMetres: id == 'coast' ? 6 : null,
      ),
    ],
  );
  static List<OceanLabSceneDefinition> decode(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    if (json['version'] != 1 || json['revision'] != 'ocean-lab-scenes-2') {
      throw const FormatException('Unknown ocean lab scene revision.');
    }
    final epoch = DateTime.parse(json['epoch'] as String);
    Vec3 vector(dynamic values) =>
        Vec3.array((values as List).map((v) => (v as num).toDouble()).toList());
    final scenes = [
      for (final value in json['scenes'] as List)
        OceanLabSceneDefinition._(
          value['id'] as String,
          value['name'] as String,
          json['revision'] as String,
          value['seed'] as int,
          (value['wind'] as num).toDouble(),
          (value['amplitude'] as num).toDouble(),
          (value['patchMetres'] as num).toDouble(),
          (value['choppiness'] as num).toDouble(),
          vector(value['camera']),
          vector(value['target']),
          epoch,
        ),
    ];
    const ids = {'calm', 'storm', 'coast', 'vessel', 'underwater', 'orbit'};
    if (!epoch.isUtc ||
        scenes.length != ids.length ||
        scenes.map((s) => s.id).toSet().difference(ids).isNotEmpty ||
        scenes.map((s) => s.id).toSet().length != ids.length) {
      throw const FormatException(
        'Six unique saved scenes and a UTC epoch are required.',
      );
    }
    for (final scene in scenes) {
      scene.sea;
    }
    return List.unmodifiable(scenes);
  }
}

enum OceanLabDetail { preview, balanced, detailed, fine }

extension OceanLabDetailSettings on OceanLabDetail {
  OceanQualitySettings get settings {
    final grid = [16, 32, 64, 128][index];
    final patches = [96, 192, 384, 768][index];
    return OceanRenderQuality.low.settings.copyWith(
      fftResolution: grid,
      maxBands: 1,
      maxPatches: patches,
      maxVertices: patches * 289,
      gpuBudgetBytes: 512 * 1024 * 1024,
      sceneInputScale: [.5, .5, .75, 1.0][index],
      ssrSteps: [0, 16, 32, 64][index],
      shaftSteps: [0, 12, 24, 48][index],
      causticResolution: [0, 64, 128, 256][index],
      sprayParticleCap: [0, 512, 1024, 2048][index],
    );
  }
}
