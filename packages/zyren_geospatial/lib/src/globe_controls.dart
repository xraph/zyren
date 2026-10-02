// Adapted from 3d-tiles-renderer 0.4.24 GlobeControls.
// Copyright 2020 California Institute of Technology. Apache-2.0.
// Modified for Dart cameras, public surface queries and ellipsoid frames.
// See licenses/3d-tiles-renderer.txt at the repository root.
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'geodesy.dart';

/// Ellipsoid navigation, horizon-aware clipping and surface dragging.
/// The ellipsoid frame supports translation, rotation and uniform scaling.
class GlobeControls extends EnvironmentControls {
  Ellipsoid ellipsoid;
  Mat4 _frame, _inverse;
  double nearMargin = .25, farMargin = 0;
  Quat globeInertia = Quat.identity;
  double globeInertiaFactor = 0;
  int _dragMode = 0, _rotationMode = 0;

  GlobeControls(
    super.camera, {
    super.scene,
    super.surfaceQuery,
    super.requestFrame,
    super.viewport,
    this.ellipsoid = Ellipsoid.wgs84,
    Mat4? ellipsoidFrame,
  }) : _frame = ellipsoidFrame ?? Mat4.identity(),
       _inverse = (ellipsoidFrame ?? Mat4.identity()).inverted() {
    _validateFrame(_frame);
    maxZoom = .01;
    useFallbackPlane = false;
    autoAdjustCameraRotation = false;
  }
  Mat4 get ellipsoidFrame => _frame;
  set ellipsoidFrame(Mat4 value) {
    checkOpen();
    _validateFrame(value);
    final inverse = value.inverted();
    _frame = value;
    _inverse = inverse;
    cancel();
    wake();
  }

  Vec3 get center =>
      Vec3(_frame.storage[12], _frame.storage[13], _frame.storage[14]);
  Vec3 get vectorToCenter => center - camera.position;
  double get distanceToCenter => vectorToCenter.length;
  double get maxWorldRadius {
    final m = _frame.storage;
    final scale = [0, 4, 8]
        .map(
          (i) => math.sqrt(
            m[i] * m[i] + m[i + 1] * m[i + 1] + m[i + 2] * m[i + 2],
          ),
        )
        .reduce(math.max);
    return ellipsoid.maximumRadius * scale;
  }

  Vec3 toLocal(Vec3 value) => _point(_inverse, value);
  Vec3 toWorld(Vec3 value) => _point(_frame, value);
  CameraRay localRay(CameraRay ray) =>
      CameraRay(toLocal(ray.origin), _direction(_inverse, ray.direction));
  @override
  Vec3 getUpDirection(Vec3 point) =>
      _direction(_frame, ellipsoid.surfaceNormal(toLocal(point)));
  @override
  Vec3 getCameraUpDirection() => getUpDirection(
    camera is OrthographicCamera
        ? virtualOrthographicPosition
        : camera.position,
  );

  double get perspectiveTransitionDistance {
    final c = camera as PerspectiveCamera;
    final tangent = math.tan(c.fieldOfView / 2), r = maxWorldRadius;
    return math.max(r / tangent, r / (tangent * viewport.aspect));
  }

  double get maxPerspectiveDistance => 2 * perspectiveTransitionDistance;
  double get orthographicTransitionZoom {
    final c = camera as OrthographicCamera;
    return math.max(c.top - c.bottom, c.right - c.left) / maxWorldRadius;
  }

  double get minOrthographicZoom {
    final c = camera as OrthographicCamera;
    return .7 *
        math.min(c.top - c.bottom, c.right - c.left) /
        (2 * maxWorldRadius);
  }

  bool get isNearControls => camera is PerspectiveCamera
      ? distanceToCenter < perspectiveTransitionDistance
      : (camera as OrthographicCamera).zoom > orthographicTransitionZoom;
  Vec3 get virtualOrthographicPosition {
    final c = camera as OrthographicCamera;
    final closest = toWorld(
      _closestPoint(localRay(CameraRay(c.position, forward))),
    );
    final size = math.max(c.top - c.bottom, c.right - c.left) / c.zoom;
    return c.position +
        forward * ((closest - c.position).dot(forward) - size * 4);
  }

  Vec3 _closestPoint(CameraRay ray) {
    final hit = ellipsoid.intersectRay(ray.origin, ray.direction);
    if (hit != null) return hit;
    final o = Vec3(
      ray.origin.x / ellipsoid.x,
      ray.origin.y / ellipsoid.y,
      ray.origin.z / ellipsoid.z,
    );
    final d = Vec3(
      ray.direction.x / ellipsoid.x,
      ray.direction.y / ellipsoid.y,
      ray.direction.z / ellipsoid.z,
    ).normalized();
    final p = (o + d * math.max(0, -o.dot(d))).normalized();
    return Vec3(p.x * ellipsoid.x, p.y * ellipsoid.y, p.z * ellipsoid.z);
  }

  @override
  NavigationHit? raycast(CameraRay ray) {
    final result = super.raycast(ray);
    if (result != null) return result;
    final local = localRay(ray);
    final hit = ellipsoid.intersectRay(local.origin, local.direction);
    if (hit == null) return null;
    final point = toWorld(hit);
    return NavigationHit(point, point.distanceTo(ray.origin));
  }

  @override
  Vec3 getPivotPoint() {
    final ray = CameraRay(camera.position, forward);
    final estimate = toWorld(_closestPoint(localRay(ray)));
    final surface = super.getPivotPoint();
    return surface == null ||
            (surface - ray.origin).dot(ray.direction) >
                (estimate - ray.origin).dot(ray.direction)
        ? estimate
        : surface;
  }

  @override
  void update(double deltaSeconds) {
    checkOpen();
    if (!deltaSeconds.isFinite || deltaSeconds < 0) {
      throw ArgumentError.value(deltaSeconds, 'deltaSeconds');
    }
    if (!enabled || deltaSeconds == 0 || !viewport.isUsable) return;
    if (!nearMargin.isFinite ||
        nearMargin <= 0 ||
        !farMargin.isFinite ||
        farMargin < 0) {
      throw ArgumentError(
        'Globe clipping margins must be finite and nonnegative, with a positive near margin.',
      );
    }
    scaleZoomOrientationAtEdges = isNearControls && zoomDelta < 0;
    final adjustRotation = needsUpdate;
    super.update(deltaSeconds);
    adjustCamera();
    if (adjustRotation && isNearControls) {
      alignCameraUp(getCameraUpDirection());
      clampRotation(getCameraUpDirection());
    }
  }

  @override
  void adjustCamera() {
    super.adjustCamera();
    final c = camera, radius = maxWorldRadius;
    if (c is PerspectiveCamera) {
      final margin = nearMargin * radius;
      final alpha = ((distanceToCenter - radius) / margin).clamp(0.0, 1.0);
      final near = math.max(
        1 + 999 * alpha,
        distanceToCenter - radius - margin,
      );
      final position = ellipsoid.fromEcef(toLocal(c.position));
      final elevation = math.max(position.height, 2550);
      // The pinned control passes cartographic radians to its degree-based
      // effective-radius helper. Retain that clipping behavior for replay.
      final phi = position.latitude * math.pi / 180;
      final eccentricity =
          1 - ellipsoid.z * ellipsoid.z / (ellipsoid.x * ellipsoid.x);
      final effectiveRadius =
          ellipsoid.x /
          math.sqrt(1 - eccentricity * math.pow(math.sin(phi), 2));
      final horizon = math.sqrt(
        2 * effectiveRadius * elevation + elevation * elevation,
      );
      c.setClippingRange(
        near,
        horizon * radius / ellipsoid.maximumRadius + .1 + radius * farMargin,
      );
    } else if (c is OrthographicCamera) {
      translate(virtualOrthographicPosition - c.position);
      final distance = vectorToCenter.dot(forward);
      final near = distance - radius * (1 + nearMargin);
      final far = distance + .1 + radius * farMargin;
      translate(forward * near);
      c.setClippingRange(0, far - near);
    }
  }

  @override
  void setState(EnvironmentState value) {
    super.setState(value);
    _dragMode = _rotationMode = 0;
  }

  @override
  void cancel() {
    super.cancel();
    globeInertia = Quat.identity;
    globeInertiaFactor = 0;
    _dragMode = _rotationMode = 0;
  }

  @override
  bool get inertiaNeedsUpdate =>
      super.inertiaNeedsUpdate || globeInertiaFactor != 0;
  @override
  void updatePosition(double dt) {
    if (state != EnvironmentState.drag || pointer == null) return;
    if (_dragMode == 0) _dragMode = isNearControls ? 1 : -1;
    final ray = localRay(pointerRay(pointer!)),
        pivotRadius = toLocal(pivotPoint).length;
    final hit = Ellipsoid(
      pivotRadius,
      pivotRadius,
      pivotRadius,
    ).intersectRay(ray.origin, ray.direction);
    if (hit == null) {
      resetState();
      updateInertia(dt);
      return;
    }
    final rotation = navigationRotationBetween(
      toWorld(hit) - center,
      pivotPoint - center,
    );
    rotateAround(center, rotation);
    if (pointerMoveDistance / dt < 2 * viewport.devicePixelRatio) {
      inertiaStableFrames++;
    } else {
      globeInertia = rotation;
      globeInertiaFactor = 1 / dt;
      inertiaStableFrames = 0;
    }
  }

  @override
  void updateRotation(double dt) {
    if (_rotationMode == 1 || isNearControls) {
      _rotationMode = 1;
      super.updateRotation(dt);
    } else {
      _rotationMode = -1;
    }
  }

  @override
  void updateInertia(double dt) {
    super.updateInertia(dt);
    if (!enableDamping || inertiaStableFrames > 1) {
      globeInertiaFactor = 0;
      globeInertia = Quat.identity;
      return;
    }
    if (globeInertiaFactor == 0) return;
    final c = camera;
    final near = c is PerspectiveCamera
        ? c.near
        : (c as OrthographicCamera).near;
    final distance = [
      near,
      cameraRadius,
      minDistance,
      inertiaTargetDistance,
    ].reduce(math.max);
    final Vec3 delta;
    if (c is PerspectiveCamera) {
      final tangent = math.tan(c.fieldOfView / 2) / c.zoom;
      delta =
          right * (-.00025 * tangent * viewport.aspect * distance) +
          (-forward).cross(right) * (-.00025 * tangent * distance);
    } else {
      final o = c as OrthographicCamera;
      delta =
          right * (.00025 * (o.right - o.left) / (2 * o.zoom)) +
          (-forward).cross(right) *
              (.00025 * (o.top - o.bottom) / (2 * o.zoom));
    }
    final position = c.position - forward * distance;
    final threshold =
        vectorAngle(position - center, position + delta - center) / dt;
    globeInertiaFactor *= math.pow(2, -dt / dampingFactor);
    final angle =
        2 * math.acos(globeInertia.w.clamp(-1, 1)) * globeInertiaFactor;
    if (angle < threshold) {
      globeInertiaFactor = 0;
      globeInertia = Quat.identity;
      return;
    }
    if (globeInertia.w == 1 &&
        (globeInertia.x != 0 || globeInertia.y != 0 || globeInertia.z != 0)) {
      globeInertia = Quat(
        globeInertia.x,
        globeInertia.y,
        globeInertia.z,
        1 - 1e-9,
      );
    }
    rotateAround(
      center,
      navigationSlerp(Quat.identity, globeInertia, globeInertiaFactor * dt),
    );
  }

  void tiltTowardsCenter(double alpha) {
    final target = (vectorToCenter.normalized() * alpha + forward * (1 - alpha))
        .normalized();
    rotateAround(camera.position, navigationRotationBetween(forward, target));
  }

  void alignCameraUpToNorth(double alpha) =>
      alignCameraUp(_direction(_frame, const Vec3(0, 0, 1)), alpha);
  @override
  void updateZoom() {
    if (state != EnvironmentState.zoom && zoomDelta == 0) return;
    final zoomingOut = zoomDelta < 0;
    dragInertia = Vec3.zero;
    rotationInertia = const ViewportPoint(0, 0);
    globeInertia = Quat.identity;
    globeInertiaFactor = 0;
    final deltaAlpha = (zoomDelta.abs() / 20).clamp(0.0, 1.0);
    final c = camera;
    if (isNearControls || zoomDelta > 0) {
      // Far zoom-out tilts the camera without a surface pivot. Its cached ray
      // can still point at the old horizon when inward zoom resumes.
      if (!isNearControls && zoomDelta > 0) zoomDirectionSet = false;
      updateZoomDirection();
      if (zoomDelta < 0 && (zoomPointSet || updateZoomPoint())) {
        final toCenter = -up;
        final upAlpha = ((1 + getUpDirection(zoomPoint).dot(toCenter)) / .05)
            .clamp(0.0, 1.0);
        final forwardAlpha = 1 - forward.dot(toCenter);
        final cameraAlpha = c is OrthographicCamera ? .05 : 1;
        final alpha = math.min(
          upAlpha * forwardAlpha * cameraAlpha * (deltaAlpha * 3).clamp(0, 1),
          .1,
        );
        final target = (forward * (1 - alpha) + toCenter * alpha).normalized();
        rotateAround(zoomPoint, navigationRotationBetween(forward, target));
        zoomDirection = (zoomPoint - c.position).normalized();
      }
      super.updateZoom();
    } else if (c is PerspectiveCamera) {
      final transition = perspectiveTransitionDistance,
          maximum = maxPerspectiveDistance;
      final distanceAlpha =
          ((distanceToCenter - transition) / (maximum - transition)).clamp(
            0.0,
            1.0,
          );
      tiltTowardsCenter(.4 * distanceAlpha * deltaAlpha);
      alignCameraUpToNorth(.2 * distanceAlpha * deltaAlpha);
      final scale =
          zoomDelta * (distanceToCenter - maxWorldRadius) * zoomSpeed * .0025;
      final clamped = math.max(
        scale,
        math.min(distanceToCenter - maximum, 0.0),
      );
      translate(vectorToCenter.normalized() * clamped);
      zoomDelta = 0;
    } else if (c is OrthographicCamera) {
      final transition = orthographicTransitionZoom,
          minimum = minOrthographicZoom;
      final distanceAlpha = (c.zoom - transition) / (minimum - transition);
      tiltTowardsCenter(.4 * distanceAlpha * deltaAlpha);
      alignCameraUpToNorth(.2 * distanceAlpha * deltaAlpha);
      final normalized = math
          .pow(.95, (zoomDelta * .05).abs() * zoomSpeed)
          .toDouble();
      final factor = zoomDelta > 0 ? 1 / normalized : normalized;
      final clamped = math.max(factor, math.min(minimum / c.zoom, 1));
      c.zoom = math.min(maxZoom, c.zoom * clamped);
      zoomDelta = 0;
      zoomDirectionSet = false;
    }
    // A coalesced scroll burst can cross both the near/far threshold and the
    // orbital limit in one frame. Apply the limit after either zoom path.
    if (c is PerspectiveCamera &&
        zoomingOut &&
        distanceToCenter > maxPerspectiveDistance + 1e-6) {
      translate(
        vectorToCenter.normalized() *
            (distanceToCenter - maxPerspectiveDistance),
      );
      tiltTowardsCenter(1);
      zoomDirectionSet = false;
    }
  }
}

Vec3 _point(Mat4 matrix, Vec3 v) {
  final m = matrix.storage;
  return Vec3(
    m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12],
    m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13],
    m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14],
  );
}

void _validateFrame(Mat4 matrix) {
  final m = matrix.storage;
  final axes = [
    for (final i in [0, 4, 8]) Vec3(m[i], m[i + 1], m[i + 2]),
  ];
  final scale = axes.first.length;
  if (m[3] != 0 ||
      m[7] != 0 ||
      m[11] != 0 ||
      m[15] != 1 ||
      scale == 0 ||
      axes.any((a) => (a.length / scale - 1).abs() > 1e-10) ||
      axes[0].dot(axes[1]).abs() > scale * scale * 1e-10 ||
      axes[0].dot(axes[2]).abs() > scale * scale * 1e-10 ||
      axes[1].dot(axes[2]).abs() > scale * scale * 1e-10) {
    throw ArgumentError(
      'Globe frames require an affine transform with rotation and uniform nonzero scale.',
    );
  }
}

Vec3 _direction(Mat4 matrix, Vec3 v) {
  final m = matrix.storage;
  return Vec3(
    m[0] * v.x + m[4] * v.y + m[8] * v.z,
    m[1] * v.x + m[5] * v.y + m[9] * v.z,
    m[2] * v.x + m[6] * v.y + m[10] * v.z,
  ).normalized();
}
