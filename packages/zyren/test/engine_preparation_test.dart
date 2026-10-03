import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'engine_output_test.dart' show SurfaceBackend;

void main() {
  test(
    'preparation permission belongs to one live engine hook and frame',
    () async {
      final other = _Probe();
      final otherBackend = SurfaceBackend();
      final otherEngine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => otherBackend,
        plugins: [other],
      );
      final probe = _Probe()..other = other;
      final backend = _PausedSurface();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [probe],
      );
      try {
        final rendering = engine.renderFrame(
          elapsed: Duration.zero,
          width: 16,
          height: 16,
          target: SurfaceTarget(backend.key, 0),
        );
        await backend.entered.future;
        expect(probe.context.isPreparingFrame(probe.frame!), isFalse);
        probe.releaseEscaped.complete();
        expect(await probe.escaped.future, isFalse);
        backend.release.complete();
        await rendering;
        expect(probe.during, [true, true]);
        expect(probe.foreignEngine, isFalse);
        expect(probe.foreignFrame, isFalse);
        expect(probe.after, isFalse);
        expect(probe.attachAllowed, isFalse);
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await engine.dispose();
        await otherEngine.dispose();
      }
      expect(probe.detachAllowed, isFalse);
    },
  );
}

final class _Probe extends ScenePlugin {
  late PluginContext context;
  FrameInfo? frame;
  _Probe? other;
  final during = <bool>[];
  bool? foreignEngine, foreignFrame, after, attachAllowed, detachAllowed;
  final releaseEscaped = Completer<void>();
  final escaped = Completer<bool>();
  @override
  String get id => 'preparation-probe';
  FrameInfo sample() => const FrameInfo(
    elapsed: Duration.zero,
    delta: Duration.zero,
    number: 0,
    width: 16,
    height: 16,
  );
  @override
  void attach(PluginContext value) {
    context = value;
    attachAllowed = context.isPreparingFrame(sample());
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    this.frame = frame;
    during.add(context.isPreparingFrame(frame));
    foreignEngine = other?.context.isPreparingFrame(frame);
    foreignFrame = context.isPreparingFrame(sample());
    unawaited(() async {
      await releaseEscaped.future;
      escaped.complete(context.isPreparingFrame(frame));
    }());
    await Future<void>.value();
    during.add(context.isPreparingFrame(frame));
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    after = context.isPreparingFrame(info);
  }

  @override
  void detach(PluginContext context) {
    detachAllowed = context.isPreparingFrame(frame ?? sample());
  }
}

final class _PausedSurface extends SurfaceBackend {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    entered.complete();
    await release.future;
    return super.render(submission);
  }
}
