import 'package:gpu3d/gpu3d.dart';
import 'package:flutter/widgets.dart';
import 'package:gpu3d/rendering.dart';
import '../presentation.dart';

/// One view attachment owns its output target and compositor registration.
abstract interface class OutputPresenter {
  Future<OutputTarget> prepare(PhysicalSize size);
  Future<PresentedFrame> present(FrameOutput output);
  Future<void> setSuspended(bool value);
  Future<void> dispose();
}

/// Platform adapters can install a presenter without changing the scene engine.
abstract interface class SurfacePresenterFactory {
  bool supports(RenderBackend backend);
  OutputPresenter create(RenderBackend backend);
}

class ReadbackPresenter implements OutputPresenter {
  final FramePresenter presenter;
  ReadbackPresenter(this.presenter);
  @override
  Future<OutputTarget> prepare(PhysicalSize size) async =>
      const ReadbackTarget();
  @override
  Future<PresentedFrame> present(FrameOutput output) {
    if (output is! ReadbackOutput) {
      throw StateError('Expected explicit readback output.');
    }
    return presenter.present(RenderedFrame.fromImage(output.image));
  }

  @override
  Future<void> setSuspended(bool value) async {}
  @override
  Future<void> dispose() => presenter.dispose();
}

/// A platform view must mount before its first output target can become ready.
abstract interface class HostedOutputPresenter implements OutputPresenter {
  Widget build(BuildContext context);

  /// Stop new work and settle pending attachment futures before awaiting draws.
  /// GPU ownership is released by dispose after any submitted work completes.
  void cancelPending();
}
