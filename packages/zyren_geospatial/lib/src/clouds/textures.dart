import 'package:zyren/zyren.dart';
import 'texture_generator.dart';

/// Linear cloud maps. Weather/turbulence use RGBA 2D images; shape/detail use
/// repeated 3D volumes. Installation retains the maps independently of your scope.
final class CloudTextures {
  final GpuResource<Texture> weather, shape, detail, turbulence;
  CloudTextures({
    required this.weather,
    required this.shape,
    required this.detail,
    required this.turbulence,
  }) {
    var bytes = 0;
    for (final entry in [
      (weather, false),
      (shape, true),
      (detail, true),
      (turbulence, false),
    ]) {
      final d = entry.$1.descriptor as TextureDescriptor;
      if (d.dimension !=
              (entry.$2 ? TextureDimension.d3 : TextureDimension.d2) ||
          !d.usage.contains(TextureUsage.sampled) ||
          d.format == TextureFormat.rgba8UnormSrgb ||
          (!entry.$2 && d.format == TextureFormat.r32Float) ||
          d.width > (entry.$2 ? 128 : 1024) ||
          d.height > (entry.$2 ? 128 : 1024) ||
          d.depth > (entry.$2 ? 128 : 1)) {
        throw ArgumentError(
          'Cloud maps require bounded, sampled, linear 2D RGBA images and 3D volumes.',
        );
      }
      bytes += d.byteLength;
    }
    if (bytes > 32 * 1024 * 1024) {
      throw ArgumentError('Cloud maps exceed 32 MiB.');
    }
  }
  List<GpuResource<Texture>> get resources => [
    weather,
    shape,
    detail,
    turbulence,
  ];
  Future<CloudTextureSet> retain(GpuScope owner) async {
    final scope = owner.createChild(label: 'cloud textures');
    try {
      final maps = [
        for (final texture in resources) await scope.resources.retain(texture),
      ];
      return CloudTextureSet._(
        scope,
        CloudTextures(
          weather: maps[0],
          shape: maps[1],
          detail: maps[2],
          turbulence: maps[3],
        ),
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  static Future<CloudTextureSet> generate(
    GpuScope owner, {
    bool Function()? isCancelled,
    int? size,
  }) async {
    final scope = owner.createChild(label: 'procedural cloud textures');
    try {
      final generator = CloudTextureGenerator(scope);
      final maps = [
        for (final kind in CloudTextureKind.values)
          (await generator.generate(
            kind,
            size: size,
            isCancelled: isCancelled,
          )).texture,
      ];
      return CloudTextureSet._(
        scope,
        CloudTextures(
          weather: maps[0],
          shape: maps[1],
          detail: maps[2],
          turbulence: maps[3],
        ),
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}

/// Four complete cloud textures, released together after their consumers retire.
final class CloudTextureSet {
  final GpuScope _scope;
  final CloudTextures textures;
  CloudTextureSet._(this._scope, this.textures);
  bool get isClosed => _scope.isClosed;
  Future<void> close() => _scope.close();
}
