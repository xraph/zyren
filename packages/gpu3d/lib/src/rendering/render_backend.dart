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

/// Optional backend contract for plugins that allocate native GPU resources.
abstract interface class ResourceBackend implements RenderBackend {
  ResourceScope createResourceScope({String label = ''});
}
