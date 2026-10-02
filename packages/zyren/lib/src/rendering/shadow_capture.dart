part of 'frame_submission.dart';

final class ShadowView {
  final int lightIndex, kind, resolution, revision;
  final List<double> viewProjection;
  final double near, far, blend;
  final ShadowSettings settings;
  ShadowView._(
    this.lightIndex,
    this.kind,
    this.resolution,
    this.revision,
    Iterable<double> matrix,
    this.near,
    this.far,
    this.blend,
    this.settings,
  ) : viewProjection = List.unmodifiable(matrix);
}

final class _ShadowLight {
  final int index, revision;
  final ShadowSettings settings;
  final List<double> worldPosition;
  final List<double> areaAxes;
  _ShadowLight(
    this.index,
    this.settings,
    this.revision,
    Iterable<double> position, {
    Iterable<double> areaAxes = const [],
  }) : worldPosition = List.unmodifiable(position),
       areaAxes = List.unmodifiable(areaAxes);
}

/// Immutable camera-relative views. Backends pack them into a bounded atlas.
final class ShadowSnapshot {
  final List<ShadowView> views;
  final List<double> forward;
  ShadowSnapshot._(Iterable<ShadowView> views, Iterable<double> forward)
    : views = List.unmodifiable(views),
      forward = List.unmodifiable(forward);

  static ShadowSnapshot capture(
    SceneSnapshot scene,
    Camera camera,
    double aspect,
  ) {
    for (final (index, mesh) in scene._meshes.indexed) {
      if (mesh['receive_shadow'] == true && mesh['pbr'] == null) {
        throw UnsupportedError('Shadow receivers require StandardMaterial.');
      }
      if (mesh['cast_shadow'] != true) continue;
      if (mesh['primitive_kind'] != 0 ||
          mesh['alpha_mode'] == 2 ||
          scene.meshShaders.containsKey(index)) {
        throw UnsupportedError(
          'Shadow casters need opaque or masked built-in triangle materials.',
        );
      }
    }
    if (scene._shadowLights.isEmpty) return ShadowSnapshot._([], [0, 0, -1]);
    final inverse = camera.viewProjection(aspect).inverted().toVectorMath();
    vm.Vector3 unproject(double x, double y, double z) {
      final point = inverse.transformed(vm.Vector4(x, y, z, 1));
      if (!point.w.isFinite || point.w.abs() < 1e-30) {
        throw ArgumentError('Invalid shadow camera projection.');
      }
      return vm.Vector3(
        point.x / point.w,
        point.y / point.w,
        point.z / point.w,
      );
    }

    final centre = unproject(0, 0, camera.depthStrategy.nearDepth);
    final forward = (unproject(0, 0, .5) - centre).normalized();
    final cameraNear = math.max(1e-5, centre.dot(forward));
    final cameraFar = camera is PerspectiveCamera
        ? camera.far
        : unproject(0, 0, camera.depthStrategy.farDepth).dot(forward);
    final rays = [
      for (final x in [-1.0, 1.0])
        for (final y in [-1.0, 1.0])
          (
            unproject(x, y, camera.depthStrategy.nearDepth),
            unproject(x, y, .5),
          ),
    ];
    List<vm.Vector3> plane(double depth) => [
      for (final (a, b) in rays)
        a + (b - a) * ((depth - a.dot(forward)) / (b - a).dot(forward)),
    ];
    final bounds = <List<vm.Vector3>>[];
    for (final mesh in scene._meshes) {
      if (mesh['cast_shadow'] != true) continue;
      final geometry = scene._geometries[mesh['geometry']]!;
      final model = vm.Matrix4.fromList((mesh['model'] as List).cast<double>());
      final instance = scene._instances[mesh['instances']];
      final deformedBounds = scene._poses[mesh['pose']]?.bounds;
      final corners = instance == null
          ? (deformedBounds?.corners ?? geometry.bounds.corners)
          : instance
                .boundsFor(
                  geometry,
                  count: mesh['instance_count'] as int,
                  localBounds: deformedBounds,
                )
                .corners;
      bounds.add([
        for (final corner in corners) model.transformed3(corner.toVectorMath()),
      ]);
    }
    final views = <ShadowView>[];
    final shadowLights = scene._shadowLights.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    for (final captured in shadowLights) {
      final settings = captured.settings;
      final isArea = settings is AreaShadow;
      final light = isArea
          ? scene._areas[captured.index - 16]
          : scene._lights[captured.index];
      vm.Vector3 vector(Object? value) {
        final values = (value as List).cast<double>();
        return vm.Vector3(values[0], values[1], values[2]);
      }

      final direction = isArea
          ? -vector(
              light['half_width'],
            ).cross(vector(light['half_height'])).normalized()
          : vector(light['direction']);
      final position = vector(light['position']);
      void add(vm.Matrix4 matrix, double near, double far, [double blend = 0]) {
        views.add(
          ShadowView._(
            captured.index,
            isArea ? 3 : light['kind'] as int,
            settings.resolution,
            captured.revision,
            matrix.storage,
            near,
            far,
            blend,
            settings,
          ),
        );
      }

      if (settings is DirectionalShadow) {
        final far = math.min(settings.distance, cameraFar);
        if (far <= cameraNear) continue;
        var previous = cameraNear;
        var previousStart = cameraNear;
        for (var i = 1; i <= settings.cascades; i++) {
          final fraction = i / settings.cascades;
          final split =
              (1 - settings.splitLambda) *
                  (cameraNear + (far - cameraNear) * fraction) +
              settings.splitLambda *
                  cameraNear *
                  math.pow(far / cameraNear, fraction);
          final start = i == 1
              ? previous
              : previous - (previous - previousStart) * settings.blend;
          final corners = [...plane(start), ...plane(split)];
          add(
            _directionalMatrix(
              corners,
              bounds,
              direction,
              camera.position.toVectorMath(),
              settings,
            ),
            previous,
            split,
            settings.blend,
          );
          previousStart = previous;
          previous = split;
        }
      } else if (settings is AreaShadow) {
        final width = vector(light['half_width']);
        final height = vector(light['half_height']);
        for (final y in [-.5, .5]) {
          for (final x in [-.5, .5]) {
            final sample = position + width * x + height * y;
            for (final direction in _cubeShadowDirections()) {
              add(
                _perspectiveShadow(
                  sample,
                  direction,
                  math.pi / 2,
                  settings.near,
                  settings.far,
                ),
                settings.near,
                settings.far,
              );
            }
          }
        }
      } else if (settings is PositionalShadow) {
        final range = light['range'] as double;
        final far = range == 0 ? settings.far : math.min(range, settings.far);
        if (far <= settings.near) {
          throw ArgumentError('Light range must exceed shadow near.');
        }
        if (settings is PointShadow) {
          for (final direction in _cubeShadowDirections()) {
            add(
              _perspectiveShadow(
                position,
                direction,
                math.pi / 2,
                settings.near,
                far,
              ),
              settings.near,
              far,
            );
          }
        } else {
          final fov = 2 * math.acos(light['outer_cos'] as double);
          if (fov < 1e-4 || fov > math.pi - 1e-4) {
            throw ArgumentError(
              'Shadowed spot cones require a finite perspective projection.',
            );
          }
          add(
            _perspectiveShadow(position, direction, fov, settings.near, far),
            settings.near,
            far,
          );
        }
      }
    }
    if (views.length > 128 ||
        views.fold<int>(
              0,
              (sum, view) => sum + view.resolution * view.resolution,
            ) >
            2048 * 2048) {
      throw ArgumentError(
        'Shadows exceed the 128-view or 2048-square atlas budget.',
      );
    }
    return ShadowSnapshot._(views, forward.storage);
  }
}

(vm.Vector3, vm.Vector3) _shadowBasis(vm.Vector3 direction) {
  final z = -direction.normalized();
  final up = z.y.abs() > .99 ? vm.Vector3(0, 0, 1) : vm.Vector3(0, 1, 0);
  final x = up.cross(z).normalized();
  return (x, z.cross(x));
}

vm.Matrix4 _perspectiveShadow(
  vm.Vector3 position,
  vm.Vector3 direction,
  double fov,
  double near,
  double far,
) {
  final (x, y) = _shadowBasis(direction);
  final z = -direction.normalized();
  final view = vm.Matrix4.identity()
    ..setRow(0, vm.Vector4(x.x, x.y, x.z, -x.dot(position)))
    ..setRow(1, vm.Vector4(y.x, y.y, y.z, -y.dot(position)))
    ..setRow(2, vm.Vector4(z.x, z.y, z.z, -z.dot(position)));
  final f = 1 / math.tan(fov / 2);
  final projection = vm.Matrix4.zero()
    ..setEntry(0, 0, f)
    ..setEntry(1, 1, f)
    ..setEntry(2, 2, far / (near - far))
    ..setEntry(2, 3, near * far / (near - far))
    ..setEntry(3, 2, -1);
  return projection * view;
}

vm.Matrix4 _directionalMatrix(
  List<vm.Vector3> corners,
  List<List<vm.Vector3>> casters,
  vm.Vector3 direction,
  vm.Vector3 origin,
  DirectionalShadow settings,
) {
  final (x, y) = _shadowBasis(direction);
  final centre =
      corners.fold(vm.Vector3.zero(), (sum, p) => sum + p) /
      corners.length.toDouble();
  var radius = corners.map((p) => (p - centre).length).reduce(math.max);
  radius = (radius * 16).ceilToDouble() / 16;
  radius *=
      settings.resolution /
      (settings.resolution - 2 * (settings.filterRadius + 2));
  final step = 2 * radius / settings.resolution;
  double snapped(vm.Vector3 axis) =>
      ((axis.dot(centre) + axis.dot(origin)) / step).roundToDouble() * step -
      axis.dot(origin);
  final cx = snapped(x), cy = snapped(y);
  var minimum = corners.map((p) => direction.dot(p)).reduce(math.min);
  var maximum = corners.map((p) => direction.dot(p)).reduce(math.max);
  for (final points in casters) {
    final xs = points.map(x.dot), ys = points.map(y.dot);
    if (xs.reduce(math.max) < cx - radius ||
        xs.reduce(math.min) > cx + radius ||
        ys.reduce(math.max) < cy - radius ||
        ys.reduce(math.min) > cy + radius) {
      continue;
    }
    minimum = math.min(minimum, points.map(direction.dot).reduce(math.min));
    maximum = math.max(maximum, points.map(direction.dot).reduce(math.max));
  }
  minimum -= 1;
  maximum += 1;
  final depth = maximum - minimum;
  return vm.Matrix4.identity()
    ..setRow(
      0,
      vm.Vector4(x.x / radius, x.y / radius, x.z / radius, -cx / radius),
    )
    ..setRow(
      1,
      vm.Vector4(y.x / radius, y.y / radius, y.z / radius, -cy / radius),
    )
    ..setRow(
      2,
      vm.Vector4(
        direction.x / depth,
        direction.y / depth,
        direction.z / depth,
        -minimum / depth,
      ),
    );
}

List<vm.Vector3> _cubeShadowDirections() => [
  vm.Vector3(1, 0, 0),
  vm.Vector3(-1, 0, 0),
  vm.Vector3(0, 1, 0),
  vm.Vector3(0, -1, 0),
  vm.Vector3(0, 0, 1),
  vm.Vector3(0, 0, -1),
];
