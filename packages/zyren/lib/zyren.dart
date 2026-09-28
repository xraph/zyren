library;

export 'src/geometry/geometry.dart' hide watchGeometry;
export 'src/geometry/vertex_attribute.dart';
export 'src/geometry/vertex_layout.dart';
export 'src/scene/scene.dart';
export 'src/spatial/raycaster.dart';
export 'src/plugins/engine.dart';
export 'src/rendering/renderer.dart';

export 'src/math/vec3.dart';
export 'src/math/quat.dart';
export 'src/math/mat4.dart';
export 'src/math/angle.dart';
export 'src/plugins/registration.dart';
export 'src/rendering/frame_submission.dart' show FrameTime;
export 'src/rendering/engine_options.dart';
export 'src/input/viewport_point.dart';
export 'src/input/pointer_event.dart';
export 'src/input/viewport_input.dart';
export 'src/controls/orbit_controls.dart';
export 'src/controls/orbit_controls_plugin.dart';
export 'src/controls/camera_transition_manager.dart';
export 'src/controls/environment_controls.dart';
export 'src/controls/environment_controls_plugin.dart';
export 'src/rendering/capabilities.dart';
export 'src/rendering/depth_strategy.dart';
export 'src/rendering/scene_issue.dart';
export 'src/plugins/attachment_scope.dart';
export 'src/assets/load_task.dart';
export 'src/assets/asset_scope.dart';
export 'src/assets/asset_request.dart';
export 'src/assets/source_resolver.dart' hide UnavailableSourceResolver;
export 'src/assets/load_cancellation.dart' show LoadCancellation;
export 'src/assets/image_decoder.dart';
export 'src/assets/buffer_decoder.dart';
export 'src/rendering/frame_output.dart'
    show ImageData, PhysicalSize, PixelFormat, ColorSpace, AlphaMode;

export 'src/resources/buffer.dart';
export 'src/resources/texture.dart';
export 'src/resources/texture_image.dart';
export 'src/resources/resource_scope.dart'
    hide
        ResourceDevice,
        ShaderDevice,
        ShaderBuild,
        GraphDevice,
        GraphDeviceDescription,
        MaterialDevice,
        EnvironmentDevice;

export 'src/lights/environment_lighting_plugin.dart';

export 'src/resources/gpu_scope.dart';
