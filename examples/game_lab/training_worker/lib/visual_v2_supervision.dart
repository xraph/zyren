import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/visual_v2.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'visual_v2_oracle.dart';

/// TRAIN-only box geometry. It never enters the actor tensor or controller.
final class VisualV2TrainingBox {
  final String sourceId;
  final Vec3 centre, halfExtents;
  VisualV2TrainingBox._(this.sourceId, this.centre, this.halfExtents);
  factory VisualV2TrainingBox.fromCapturedWorld({
    required String sourceId,
    required PhysicsPose pose,
    required BoxShape shape,
    required CameraObservation captured,
  }) {
    final cameraPosition = captured.capturedCameraPosition;
    final rotation = captured.capturedCameraRotation;
    if (sourceId.isEmpty ||
        sourceId.length > 128 ||
        cameraPosition == null ||
        rotation == null) {
      throw ArgumentError('TRAIN shape needs captured camera provenance.');
    }
    final inverse = Quat(-rotation.x, -rotation.y, -rotation.z, rotation.w);
    final centre = inverse.rotate(pose.position - cameraPosition);
    final orientation = inverse * pose.rotation;
    final x = orientation.rotate(Vec3(shape.halfExtents.x, 0, 0));
    final y = orientation.rotate(Vec3(0, shape.halfExtents.y, 0));
    final z = orientation.rotate(Vec3(0, 0, shape.halfExtents.z));
    final half = Vec3(
      x.x.abs() + y.x.abs() + z.x.abs(),
      x.y.abs() + y.y.abs() + z.y.abs(),
      x.z.abs() + y.z.abs() + z.z.abs(),
    );
    if (!centre.isFinite ||
        !half.isFinite ||
        centre.length > 10000 ||
        half.storage.any((v) => v <= 0 || v > 20)) {
      throw ArgumentError('TRAIN box exceeds label bounds.');
    }
    return VisualV2TrainingBox._(sourceId, centre, half);
  }
}

/// Unknown geometry is excluded from the regression loss, not labelled absent.
final class VisualV2Supervision {
  final VisualEstimate estimate;
  final List<int> mask;
  final String cameraProfileHash;
  final int captureTick, worldRevision, visibleComponents;
  final bool fullRasterObservable;
  VisualV2Supervision._(
    this.estimate,
    List<int> mask,
    this.cameraProfileHash,
    this.captureTick,
    this.worldRevision,
    this.visibleComponents,
    this.fullRasterObservable,
  ) : mask = List.unmodifiable(mask);
  Map<String, Object?> toJson() => {
    'schema': 'visual-navigation-v2-supervision-1',
    'estimate': estimate.values,
    'mask': mask,
    'profile_hash': estimate.profileHash,
    'camera_profile_hash': cameraProfileHash,
    'capture_tick': captureTick,
    'world_revision': worldRevision,
    'visible_components': visibleComponents,
    'full_raster_observable': fullRasterObservable,
    'negative_scope': 'entire-declared-84x84-class-search-raster',
    'geometry_source':
        'TRAIN-only-declared-box-with-current-raster-depth-support',
  };
}

/// Combined labels use real camera classes and depth. Unsupported or cropped
/// objects remain uncertain. RGB/depth-only students must receive selected planes.
VisualV2Supervision visualV2Supervision(
  CameraObservation captured,
  VisualNavigationProfile profile, {
  List<VisualV2TrainingBox> boxes = const [],
}) {
  if (profile.mode != 'combined' ||
      captured.cameraProfileHash != profile.camera.hash ||
      captured.capturedActorPose == null ||
      captured.capturedCameraPosition == null ||
      captured.capturedCameraRotation == null ||
      captured.receipt.tick % 5 != 0 ||
      captured.receipt.width != 84 ||
      captured.receipt.height != 84 ||
      captured.receipt.depth == null ||
      boxes.length > 64 ||
      boxes.map((b) => b.sourceId).toSet().length != boxes.length) {
    throw ArgumentError('TRAIN supervision capture or declared boxes differ.');
  }
  final image = captured.receipt.image, depth = captured.receipt.depth!;
  if (image.colorSpace != ColorSpace.srgb) {
    throw ArgumentError('TRAIN classes require sRGB.');
  }
  final values = List<double>.from(
    visualV2RasterOracle(captured, profile).values,
  );
  final mask = List<int>.filled(74, 0),
      blue = List<bool>.filled(84 * 84, false);
  var observable = true;
  final tangent = math.tan(profile.camera.fieldOfView / 2);
  for (var i = 0; i < 84 * 84; i++) {
    final x = i % 84, y = i ~/ 84, p = y * image.rowStride + x * 4;
    final r = image.pixels[p + (image.format == PixelFormat.rgba8 ? 0 : 2)],
        g = image.pixels[p + 1],
        b = image.pixels[p + (image.format == PixelFormat.rgba8 ? 2 : 0)];
    final known =
        depth.validity[i] == 1 &&
        depth.metres[i] >= profile.camera.near &&
        depth.metres[i] <= 40 &&
        depth.metres[i] *
                math.sqrt(1 + math.pow((2 * (x + .5) / 84 - 1) * tangent, 2)) <=
            40;
    final isBlue = b > r * 2 && b > g * 2 && b > 100;
    final isGround = g > r * 2 && g > b * 2 && g > 100;
    final isCue = r > g * 2 && r > b * 2 && r > 100;
    if (!known || !(isBlue || isGround || isCue)) observable = false;
    blue[i] = known && isBlue;
  }
  // Presence can be trained when supported. Absence requires a complete raster.
  if (values[6] >= .9 && values[7] >= .9) {
    mask.fillRange(0, 8, 1);
  } else if (observable) {
    mask[6] = 1;
    mask[7] = 1;
  }
  for (var i = 56; i < 74; i += 2) {
    if (values[i] >= .9) {
      mask[i] = 1;
      mask[i + 1] = 1;
    }
  }
  final visited = List<bool>.filled(84 * 84, false), components = <List<int>>[];
  for (var i = 0; i < blue.length; i++) {
    if (!blue[i] || visited[i]) continue;
    final members = <int>[i];
    visited[i] = true;
    for (var cursor = 0; cursor < members.length; cursor++) {
      final at = members[cursor], x = at % 84, y = at ~/ 84;
      for (final next in [
        if (x > 0) at - 1,
        if (x < 83) at + 1,
        if (y > 0) at - 84,
        if (y < 83) at + 84,
      ]) {
        if (blue[next] && !visited[next]) {
          visited[next] = true;
          members.add(next);
        }
      }
    }
    if (members.length < 3) {
      observable = false;
      continue;
    }
    components.add(members);
  }
  if (components.length > 8) observable = false;
  double midpoint(List<int> pixels) =>
      pixels.fold<int>(0, (n, i) => n + i % 84) / pixels.length;
  components.sort((a, b) => midpoint(a).compareTo(midpoint(b)));
  final used = <String>{};
  for (var slot = 0; slot < math.min(8, components.length); slot++) {
    final members = components[slot];
    final memberSet = members.toSet();
    var lateral = 0.0, forward = 0.0;
    for (final pixel in members) {
      final distance = depth.metres[pixel];
      lateral += -(2 * ((pixel % 84) + .5) / 84 - 1) * tangent * distance;
      forward += distance;
    }
    final offset = 8 + slot * 6;
    values.setRange(offset, offset + 6, [
      lateral / members.length,
      forward / members.length,
      0,
      0,
      10,
      1,
    ]);
    mask[offset + 4] = 1;
    mask[offset + 5] = 1;
    final supported = boxes.where((box) {
      if (used.contains(box.sourceId)) return false;
      final c = box.centre, h = box.halfExtents;
      if (c.z - h.z < profile.camera.near || c.z + h.z > 40) return false;
      var left = 84.0, right = 0.0, top = 84.0, bottom = 0.0;
      for (final dx in [-h.x, h.x]) {
        for (final dy in [-h.y, h.y]) {
          for (final dz in [-h.z, h.z]) {
            final x = (1 - (c.x + dx) / ((c.z + dz) * tangent)) * 42;
            final y = (1 - (c.y + dy) / ((c.z + dz) * tangent)) * 42;
            left = math.min(left, x);
            right = math.max(right, x);
            top = math.min(top, y);
            bottom = math.max(bottom, y);
          }
        }
      }
      if (left < 1 || right > 83 || top < 1 || bottom > 83) return false;
      var support = 0, total = 0;
      for (var y = top.ceil(); y < bottom.floor(); y++) {
        for (var x = left.ceil(); x < right.floor(); x++) {
          final i = y * 84 + x;
          total++;
          if (blue[i] &&
              depth.metres[i] >= c.z - h.z - .2 &&
              depth.metres[i] <= c.z + h.z + .2 &&
              memberSet.contains(i)) {
            support++;
          }
        }
      }
      return total >= 3 && support / total >= .9;
    }).toList();
    if (supported.length == 1 && supported.single.centre.length <= 40) {
      final box = supported.single;
      used.add(box.sourceId);
      values.setRange(offset, offset + 6, [
        box.centre.x,
        box.centre.z,
        box.halfExtents.x,
        box.halfExtents.z,
        .1,
        1,
      ]);
      mask.fillRange(offset, offset + 6, 1);
    }
  }
  // A blue surface can occlude another object. Only a wholly free class raster
  // can establish absence for unused visible-object slots.
  if (observable && components.isEmpty) {
    for (var slot = components.length; slot < 8; slot++) {
      mask[8 + slot * 6 + 5] = 1;
    }
  }
  final estimate = VisualEstimate.decode(values, profile: profile);
  return VisualV2Supervision._(
    estimate,
    mask,
    profile.camera.hash,
    captured.receipt.tick,
    captured.worldRevision,
    components.length,
    observable,
  );
}
