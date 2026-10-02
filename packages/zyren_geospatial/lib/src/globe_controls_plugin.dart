import 'package:zyren/zyren.dart';
import 'geospatial_plugin.dart';
import 'globe_controls.dart';

/// Attaches globe navigation using the engine's shared geospatial reference.
class GlobeControlsPlugin extends EnvironmentControlsPlugin {
  final Mat4? ellipsoidFrame;
  final void Function(GlobeControls)? configureGlobe;
  GlobeControlsPlugin({this.ellipsoidFrame, this.configureGlobe});
  @override
  String get id => 'geospatial.globe-controls';
  @override
  Set<String> get dependencies => const {GeospatialPlugin.pluginId};
  @override
  GlobeControls? get controls => super.controls as GlobeControls?;
  @override
  GlobeControls createControls(PluginContext context) {
    final input = context.input;
    final controls = GlobeControls(
      context.camera,
      scene: context.scene,
      ellipsoid: context.service(geospatialReference).ellipsoid,
      ellipsoidFrame: ellipsoidFrame,
      viewport: input is ViewportInputSource
          ? input.viewport
          : const ViewportMetrics(1, 1),
      requestFrame: context.invalidate,
    );
    configureGlobe?.call(controls);
    return controls;
  }
}
