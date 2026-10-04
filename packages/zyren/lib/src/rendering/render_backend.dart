import 'capabilities.dart';
import 'frame_output.dart';
import 'frame_submission.dart';
import '../resources/resource_scope.dart';
import '../resources/texture.dart';

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

/// Optional GPU-only capture on the presenter's device.
abstract interface class CaptureBackend implements RenderBackend {
  Future<SceneCaptureView> createCaptureView();
}

/// An independent view with one queued job at a time. Capture never runs engine
/// hooks. Close the lease before its backend; accepted GPU work retains resources
/// until the native queue completes, including when you close an output scope.
abstract interface class SceneCaptureView {
  void configureSceneUploadBudget(int bytes);
  Future<void> clear();
  Future<SceneCaptureReceipt> capture(
    FrameSubmission submission,
    GpuResource<Texture> target,
  );
  Future<void> close();
}

/// Queue acceptance for linear HDR capture, not a presentation or completion.
final class SceneCaptureReceipt {
  final SceneAdmission admission;
  final int drawCalls, uploadedBytes, attachmentBytes;

  /// Shared device energy table present during this capture, not incremental bytes.
  final int sharedEnergyLutBytes;
  final Duration cpuSubmitTime;
  const SceneCaptureReceipt({
    required this.admission,
    required this.drawCalls,
    required this.uploadedBytes,
    required this.attachmentBytes,
    required this.sharedEnergyLutBytes,
    required this.cpuSubmitTime,
  });
  int get readbackBytes => 0;
  Duration? get gpuTime => null;
}
