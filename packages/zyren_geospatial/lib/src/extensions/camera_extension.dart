import 'package:zyren/zyren.dart';
import '../globe_controls.dart';
import '../globe_controls_plugin.dart';
import 'context.dart';
import 'extension.dart';

/// Globe navigation with its own input registrations and core attachment.
final class GlobeCameraExtension extends GeospatialExtension {
  @override
  final String localId;
  final Mat4? ellipsoidFrame;
  final void Function(GlobeControls)? configure;
  late final GlobeControlsPlugin camera = GlobeControlsPlugin(
    instanceId: '$id.controls',
    additionalDependencies: {id},
    ellipsoidFrame: ellipsoidFrame,
    configureGlobe: configure,
  );
  GlobeCameraExtension({
    required String id,
    this.ellipsoidFrame,
    this.configure,
  }) : localId = id;
  @override
  List<ScenePlugin> get adapters => [camera];
  @override
  Set<String> get exclusiveCapabilities => const {'camera-rig'};
  @override
  Set<String> get incompatiblePluginIds => const {
    'geospatial.globe-controls',
    'geospatial.orbit',
    'zyren.environment-controls',
    'zyren.orbit-controls',
  };
  @override
  void attachGeospatial(GeospatialContext context) {}
}
