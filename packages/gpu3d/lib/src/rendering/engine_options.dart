enum RenderMode { onDemand, continuous }

enum PresentationPolicy { requireSharedTexture, allowReadback, readbackOnly }

enum RecoveryPolicy { manual, automaticOnce }

class EngineOptions {
  final RenderMode renderMode;
  final PresentationPolicy presentation;
  final RecoveryPolicy recovery;
  final int maxFramesPerSecond, maxFramesInFlight;
  const EngineOptions({
    this.renderMode = RenderMode.onDemand,
    this.presentation = PresentationPolicy.requireSharedTexture,
    this.recovery = RecoveryPolicy.manual,
    this.maxFramesPerSecond = 60,
    this.maxFramesInFlight = 2,
  });
  void validate() {
    if (maxFramesPerSecond < 1 ||
        maxFramesPerSecond > 1000000 ||
        maxFramesInFlight < 1) {
      throw ArgumentError('Frame rate and in-flight limits must be positive.');
    }
  }
}
