part of 'engine.dart';

final class _PluginCaptureView implements SceneCaptureView {
  final SceneCaptureView _view;
  Registration? registration;
  Future<void>? _closing;
  _PluginCaptureView(this._view);
  void _check() {
    if (_closing != null) throw StateError('Plugin capture view closed.');
  }

  @override
  void configureSceneUploadBudget(int bytes) {
    _check();
    _view.configureSceneUploadBudget(bytes);
  }

  @override
  Future<void> clear() async {
    _check();
    await _view.clear();
  }

  @override
  Future<SceneCaptureReceipt> capture(
    FrameSubmission submission,
    GpuResource<Texture> target,
  ) async {
    _check();
    return _view.capture(submission, target);
  }

  @override
  Future<void> close() {
    if (_closing case final closing?) return closing;
    final done = Completer<void>();
    _closing = done.future;
    registration?.dispose();
    Future<void>.sync(
      _view.close,
    ).then(done.complete, onError: done.completeError);
    return done.future;
  }
}
