/// Advanced backend contracts. Normal scene construction uses zyren.dart.
library;

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
        MeshShaderDevice,
        MeshShaderDeviceDescription,
        GraphDevice,
        GraphDeviceDescription;

export 'src/rendering/color_pipeline.dart';

export 'src/rendering/temporal_aa_options.dart';
