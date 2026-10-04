import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/visual_v2.dart';

/// TRAIN fixture oracle for repository-authored red cue/green floor/blue wall.
/// It reads actual A6 pixels/depth only. It has no body or target resolver.
/// This deterministic raster rule is not a learned or accepted perception model.
VisualEstimate visualV2RasterOracle(
  CameraObservation observation,
  VisualNavigationProfile profile,
) {
  if (profile.mode != 'combined' ||
      observation.cameraProfileHash != profile.camera.hash ||
      observation.receipt.depth == null ||
      observation.receipt.width != 84 ||
      observation.receipt.height != 84 ||
      observation.receipt.colorSpace != ColorSpace.srgb) {
    throw ArgumentError(
      'The TRAIN oracle requires actual combined A6 readback.',
    );
  }
  final image = observation.receipt.image, depth = observation.receipt.depth!;
  final output = [...VisualEstimate.spec.fallbackContinuous];
  final floor = List.filled(84, 0.0),
      blocked = List.filled(84, 40.0),
      samples = List.filled(84, 0);
  var lateral = 0.0, forward = 0.0, cuePixels = 0;
  final tangent = math.tan(profile.camera.fieldOfView / 2);
  for (var y = 0; y < 84; y++) {
    for (var x = 0; x < 84; x++) {
      final i = y * 84 + x, p = y * image.rowStride + x * 4;
      if (depth.validity[i] != 1) continue;
      final distance = depth.metres[i];
      if (!distance.isFinite ||
          distance < profile.camera.near ||
          distance > 40) {
        continue;
      }
      // A6 perspective +Z has camera right -X. Native tests pin this sign.
      final cameraX = -(2 * (x + .5) / 84 - 1) * tangent * distance;
      final radial = math.sqrt(cameraX * cameraX + distance * distance);
      final r = image.pixels[p + (image.format == PixelFormat.rgba8 ? 0 : 2)],
          g = image.pixels[p + 1],
          b = image.pixels[p + (image.format == PixelFormat.rgba8 ? 2 : 0)];
      final cue = r > g * 2 && r > b * 2 && r > 100;
      final ground = g > r * 2 && g > b * 2 && g > 100;
      if (cue) {
        lateral += cameraX;
        forward += distance;
        cuePixels++;
      }
      if (ground) {
        floor[x] = math.max(floor[x], radial);
        samples[x]++;
      } else {
        blocked[x] = math.min(blocked[x], radial);
      }
    }
  }
  if (cuePixels >= 3) {
    // The known TRAIN cue is a .25m sphere. Compensate its visible front face.
    output.setRange(0, 8, [
      lateral / cuePixels,
      forward / cuePixels + .25,
      0,
      0,
      .1,
      0,
      1,
      1,
    ]);
  }
  for (var sector = 0; sector < 9; sector++) {
    var free = 40.0, columns = 0, known = true;
    for (var x = 0; x < 84; x++) {
      final angle = math.atan(-(2 * (x + .5) / 84 - 1) * tangent);
      final slot =
          ((angle + profile.camera.fieldOfView / 2) /
                  profile.camera.fieldOfView *
                  9)
              .floor()
              .clamp(0, 8);
      if (slot != sector) continue;
      columns++;
      if (samples[x] < 3) known = false;
      // Subtract camera displacement, pixel raster margin and swept footprint.
      free = math.min(
        free,
        math.min(floor[x], blocked[x]) -
            math.sqrt(
              profile.camera.offset.x * profile.camera.offset.x +
                  profile.camera.offset.z * profile.camera.offset.z,
            ) -
            VisualNavigationProfile.clearanceRasterMargin -
            profile.footprintRadius -
            VisualNavigationProfile.clearanceFootprintPadding,
      );
    }
    if (known && columns > 0 && free > 0) {
      output[56 + sector * 2] = 1;
      output[57 + sector * 2] = free.clamp(0, 40);
    }
  }
  // Cropped/offscreen cue contours cannot produce a trustworthy labelled goal.
  try {
    return VisualEstimate.decode(output, profile: profile);
  } on ArgumentError {
    output.setRange(0, 8, VisualEstimate.spec.fallbackContinuous.take(8));
    return VisualEstimate.decode(output, profile: profile);
  }
}
