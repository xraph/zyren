part of '../zyren_studio.dart';

/// Saved lighting shared by the editor, previews and runtime scene streams.
final class StudioEnvironment {
  final int background, groundColor;
  final double keyIntensity, fillIntensity, keyPitch, keyYaw;
  StudioEnvironment({
    this.background = 0x14242b,
    this.groundColor = 0x262e40,
    this.keyIntensity = 3,
    this.fillIntensity = .7,
    this.keyPitch = -.5,
    this.keyYaw = -.5,
  }) {
    if ([background, groundColor].any((v) => v < 0 || v > 0xffffff) ||
        [
          keyIntensity,
          fillIntensity,
        ].any((v) => !v.isFinite || v < 0 || v > 100) ||
        [keyPitch, keyYaw].any((v) => !v.isFinite)) {
      throw ArgumentError('Invalid scene environment.');
    }
  }
  Group apply(Scene scene) {
    scene.background = Color3.hex(background);
    return scene.add(
      Group(name: 'Scene lighting')
        ..add(
          DirectionalLight(intensity: keyIntensity)
            ..rotateY(keyYaw)
            ..rotateX(keyPitch),
        )
        ..add(
          HemisphereLight(
            intensity: fillIntensity,
            groundColor: Color3.hex(groundColor),
          ),
        ),
    );
  }

  Map<String, Object?> toJson() => {
    'background': background,
    'groundColor': groundColor,
    'keyIntensity': keyIntensity,
    'fillIntensity': fillIntensity,
    'keyPitch': keyPitch,
    'keyYaw': keyYaw,
  };
  factory StudioEnvironment.fromJson(Map<String, dynamic> json) =>
      StudioEnvironment(
        background: json['background'] as int,
        groundColor: json['groundColor'] as int,
        keyIntensity: (json['keyIntensity'] as num).toDouble(),
        fillIntensity: (json['fillIntensity'] as num).toDouble(),
        keyPitch: (json['keyPitch'] as num).toDouble(),
        keyYaw: (json['keyYaw'] as num).toDouble(),
      );
}
