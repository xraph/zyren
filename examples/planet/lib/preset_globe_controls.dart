import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

/// Keep a preset fixed while coarse tiles arrive. Surface clearance starts when
/// you first navigate, matching the source globe's initial-load policy.
final class PresetGlobeControlsPlugin extends GlobeControlsPlugin {
  PresetGlobeControlsPlugin()
    : super(
        configureGlobe: (controls) {
          controls.enableDamping = true;
          controls.adjustHeight = false;
        },
      );

  @override
  void attach(PluginContext context) {
    super.attach(context);
    final current = controls!;
    context.scope.listen(current.events, (event) {
      if (event == NavigationEvent.start) current.adjustHeight = true;
    });
  }

  /// Call after changing the camera pose so the next surface query uses the new
  /// local up vector instead of the previous location's frame.
  void resetForPreset() {
    final current = controls;
    if (current == null) return;
    current.cancel();
    current.adjustHeight = false;
    current.setFrame(current.getCameraUpDirection());
  }
}
