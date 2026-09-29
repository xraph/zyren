import 'package:zyren/rendering.dart';
import '../diagnostics/renderer_info.dart';

sealed class SceneStatus {
  final int generation;
  const SceneStatus(this.generation);
}

final class SceneDetached extends SceneStatus {
  const SceneDetached(super.generation);
}

final class SceneInitializing extends SceneStatus {
  const SceneInitializing(super.generation);
}

final class SceneReady extends SceneStatus {
  final RendererInfo info;
  const SceneReady(super.generation, this.info);
}

final class SceneSuspended extends SceneStatus {
  const SceneSuspended(super.generation);
}

final class SceneRecovering extends SceneStatus {
  const SceneRecovering(super.generation);
}

final class SceneFailed extends SceneStatus {
  final SceneIssue issue;
  const SceneFailed(super.generation, this.issue);
}

final class SceneDisposed extends SceneStatus {
  const SceneDisposed(super.generation);
}
