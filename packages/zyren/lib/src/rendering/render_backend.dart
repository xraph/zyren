import 'capabilities.dart';
import 'frame_output.dart';
import 'frame_submission.dart';
import '../resources/resource_scope.dart';

/// Owns one native session. Closing waits for pending work and is idempotent.
abstract interface class RenderBackend {
  DeviceCapabilities get capabilities;
  Future<FrameOutput> render(FrameSubmission submission);
  Future<void> close();
}

/// Optional pacing for scene uploads. This does not change resource residency.
abstract interface class SceneUploadBudgetBackend implements RenderBackend {
  /// Small targets reduce upload bursts. An indivisible asset can exceed the
  /// target when admitted alone, within the backend's hard safety limits.
  void configureSceneUploadBudget(int bytes);
}

/// Optional backend contract for plugins that allocate native GPU resources.
abstract interface class ResourceBackend implements RenderBackend {
  ResourceScope createResourceScope({String label = ''});
}

/// Optional native module compiler. Executable passes require graph support too.
abstract interface class ShaderBackend implements ResourceBackend {
  ShaderCompiler createShaderCompiler({String label = ''});
}

/// Validates and executes custom passes on explicitly scoped resources.
abstract interface class GraphBackend implements ShaderBackend {
  GraphCompiler createGraphCompiler({String label = ''});
}

abstract interface class MaterialBackend implements GraphBackend {
  MaterialCompiler createMaterialCompiler({String label = ''});
}
