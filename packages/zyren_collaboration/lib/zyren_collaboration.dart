/// Shared scene edits with host-owned identity, transport and authorization.
library;

export 'src/model.dart'
    show
        SceneObjectId,
        SceneTransform,
        SceneField,
        SceneObjectState,
        SceneSnapshot;
export 'src/protocol.dart';
export 'src/local_authority.dart';
export 'src/client.dart';
export 'src/scene_plugin.dart';
