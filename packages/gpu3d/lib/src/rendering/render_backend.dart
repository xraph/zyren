import 'capabilities.dart';
import 'frame_output.dart';
import 'frame_submission.dart';

/// Owns one native session. Closing waits for pending work and is idempotent.
abstract interface class RenderBackend {
  DeviceCapabilities get capabilities;
  Future<FrameOutput> render(FrameSubmission submission);
  Future<void> close();
}
