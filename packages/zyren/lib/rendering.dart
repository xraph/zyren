/// Advanced backend contracts. Normal scene construction uses zyren.dart.
library;

export 'src/rendering/gpu_diagnostics.dart';

export 'src/rendering/capabilities.dart';
export 'src/rendering/frame_output.dart';
export 'src/rendering/frame_submission.dart';
export 'src/rendering/render_backend.dart';
export 'src/rendering/scene_issue.dart';
export 'src/rendering/frame_scheduler.dart';

export 'src/resources/resource_scope.dart'
    show
        ResourceDevice,
        ShaderDevice,
        ShaderBuild,
        GraphDevice,
        GraphDeviceDescription,
        MaterialDevice,
        EnvironmentDevice;
