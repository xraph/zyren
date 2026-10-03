import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';

List<Map<String, Object?>> navigationTileFailures(
  List<TileFailure3D>? failures,
) => [
  for (final failure in failures ?? const <TileFailure3D>[])
    {
      'code': failure.code.name,
      'httpStatus': failure.httpStatus,
      'attempts': failure.attempts,
    },
];
