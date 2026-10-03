import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

/// Opt in with the scene's saved geodetic origin. Scene axes are east/up/south.
StudioEditorContribution geospatialPlacementContribution({
  required Geodetic origin,
}) {
  final frame = EastNorthUpFrame(origin);
  Vec3 transform(Mat4 matrix, Vec3 position) => Vec3.fromVectorMath(
    matrix.toVectorMath().transform3(position.toVectorMath()),
  );
  Mat4 parent(StudioEditorContext context) =>
      context.scene.tools.selected?.parent?.worldMatrix ?? Mat4.identity();
  return StudioEditorContribution(
    id: 'geospatial.placement',
    version: 1,
    attach: (context) => context.registerPlacement(
      StudioEditorPlacement(
        id: 'geospatial.wgs84',
        title: 'World placement',
        labels: const ['Longitude', 'Latitude', 'Altitude'],
        units: const ['degrees', 'degrees', 'm (ellipsoid)'],
        precision: 6,
        applies: (context) => context.selectedId != null,
        toDisplay: (context, local) {
          final world = transform(parent(context), local);
          final coordinate = Ellipsoid.wgs84.fromEcef(
            frame.toEcef(Vec3(world.x, -world.z, world.y)),
          );
          return Vec3(
            coordinate.longitudeDegrees,
            coordinate.latitudeDegrees,
            coordinate.height,
          );
        },
        toLocal: (context, display) {
          if (display.x.abs() > 180 || display.y.abs() > 90) {
            throw ArgumentError(
              'Longitude must be within ±180 and latitude within ±90 degrees.',
            );
          }
          final enu = frame.toLocal(
            Geodetic.degrees(display.x, display.y, display.z).toEcef(),
          );
          return transform(
            parent(context).inverted(),
            Vec3(enu.x, enu.z, -enu.y),
          );
        },
      ),
    ),
  );
}
