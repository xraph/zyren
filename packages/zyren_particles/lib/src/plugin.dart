import 'package:zyren/zyren.dart';
import 'settings.dart';
import 'simulation.dart';
import 'renderer.dart';

const particleSystems = ServiceKey<ParticleController>('particles.controller');

final class ParticleEmitter {
  final String name;
  final ParticleSettings settings;
  final Object3D object;
  final bool autoStart;
  ParticleEmitter({
    required this.name,
    required this.settings,
    Object3D? object,
    this.autoStart = true,
  }) : object = object ?? Group(name: name) {
    if (name.isEmpty || name.length > 128) {
      throw ArgumentError('Emitter name requires 1 to 128 characters.');
    }
  }
}

/// Each attachment owns independent resources. Reattachment starts fresh.
final class ParticlePlugin extends ScenePlugin {
  final List<ParticleEmitter> emitters;
  final String pluginId;
  ParticleController? _controller;
  ParticlePlugin({
    required Iterable<ParticleEmitter> emitters,
    this.pluginId = 'particles',
  }) : emitters = List.unmodifiable(emitters) {
    if (this.emitters.isEmpty ||
        this.emitters.length > 32 ||
        this.emitters.map((e) => e.name).toSet().length !=
            this.emitters.length ||
        this.emitters.map((e) => e.object).toSet().length !=
            this.emitters.length) {
      throw ArgumentError('Use 1 to 32 independently named emitter objects.');
    }
  }
  @override
  String get id => pluginId;
  ParticleController get controller =>
      _controller ?? (throw StateError('Particles are not attached.'));
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.shaderMaterials,
    if (emitters.any((e) => e.settings.path == ParticlePath.gpu)) ...{
      RenderFeature.compute,
      RenderFeature.renderGraphs,
    },
  };
  @override
  Future<void> attach(PluginContext context) async {
    final control = _controller = ParticleController._(
      context,
      context.createGpuScope(label: 'particle systems'),
    );
    context.scope.onClose(control._close);
    context.provide(particleSystems, control);
    for (final emitter in emitters) {
      await control._add(emitter);
    }
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) =>
      controller._frame(frame);
}

final class ParticleController {
  final PluginContext _context;
  final GpuScope _owner;
  final Map<String, _EmitterRuntime> _emitters = {};
  Future<void> _queue = Future.value();
  Registration? _demand;
  bool _closed = false;
  ParticleController._(this._context, this._owner);
  bool get isClosed => _closed || _owner.isClosed;
  List<String> get names => List.unmodifiable(_emitters.keys);
  ParticlePlayback playback(String name) => _get(name).clock.playback;
  ParticleMeasurements measurements(String name) =>
      _get(name).renderer.measurements;
  double pendingSeconds(String name) => _get(name).clock.pendingSeconds;
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) {
      if (isClosed) throw StateError('Particles have closed.');
      return action();
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  _EmitterRuntime _get(String name) =>
      _emitters[name] ??
      (throw ArgumentError.value(name, 'name', 'Unknown emitter.'));
  Future<void> _add(ParticleEmitter emitter) async {
    final existing = _emitters[emitter.name];
    if (existing != null) throw ArgumentError('Emitter already exists.');
    var root = emitter.object;
    while (root.parent != null) {
      root = root.parent!;
    }
    final added = emitter.object.parent == null;
    if (!added && !identical(root, _context.scene)) {
      throw ArgumentError('Emitter belongs to another scene.');
    }
    final renderer = await ParticleRenderer.create(_owner, emitter.settings);
    if (added) _context.scene.add(emitter.object);
    emitter.object.add(renderer.mesh);
    if (renderer.ribbon case final ribbon?) emitter.object.add(ribbon);
    final runtime = _EmitterRuntime(emitter, renderer, added);
    _emitters[emitter.name] = runtime;
    if (emitter.autoStart) {
      runtime.clock.start();
      if (emitter.settings.prewarm > 0) {
        final ticks = runtime.clock.advance(
          emitter.settings.prewarm,
          maxSteps: 4096,
        );
        await renderer.update(
          ticks,
          emitter: _world(emitter.object),
          camera: _world(_context.camera),
        );
        while (runtime.clock.pendingSeconds + 1e-12 >=
            emitter.settings.fixedStep) {
          await renderer.update(
            runtime.clock.advance(0, maxSteps: 4096),
            emitter: _world(emitter.object),
            camera: _world(_context.camera),
          );
        }
      }
    }
    _updateDemand();
  }

  Future<void> add(ParticleEmitter emitter) => _serial(() => _add(emitter));
  Future<void> remove(String name) => _serial(() async {
    final runtime = _get(name);
    _emitters.remove(name);
    await runtime.renderer.close();
    if (runtime.added) {
      runtime.emitter.object.parent?.remove(runtime.emitter.object);
    }
    _updateDemand();
    _context.invalidate();
  });
  Future<void> start(String name) => _serial(() async {
    final e = _get(name);
    if (e.clock.playback == ParticlePlayback.stopped) await e.renderer.reset();
    e.clock.start();
    _updateDemand();
    _context.invalidate();
  });
  Future<void> pause(String name) => _serial(() async {
    _get(name).clock.pause();
    _updateDemand();
  });
  Future<void> resume(String name) => _serial(() async {
    _get(name).clock.resume();
    _updateDemand();
  });
  Future<void> stop(String name, {bool clear = false}) => _serial(() async {
    final e = _get(name);
    e.clock.stop(clear: clear);
    if (clear) await e.renderer.reset();
    _updateDemand();
    _context.invalidate();
  });
  Future<void> reset(String name) => _serial(() async {
    final e = _get(name);
    e.clock.reset();
    await e.renderer.reset();
    _updateDemand();
    _context.invalidate();
  });
  Future<void> burst(String name, int count) => _serial(() async {
    final e = _get(name);
    e.clock.burst(count);
    if (e.clock.playback == ParticlePlayback.stopped) e.clock.stop();
    _updateDemand();
    _context.invalidate();
  });
  Future<List<ParticleSnapshot>> inspect(String name) =>
      _serial(() => _get(name).renderer.inspect());

  /// Rebuild scoped resources after renderer recovery. GPU state restarts from
  /// the seed; this explicit reset avoids pretending lost device memory survived.
  Future<void> restore(String name) => _serial(() async {
    final e = _get(name);
    final candidate = await ParticleRenderer.create(_owner, e.emitter.settings);
    final previous = e.renderer;
    e.renderer = candidate;
    e.clock.reset();
    e.clock.start();
    e.emitter.object.add(candidate.mesh);
    if (candidate.ribbon case final ribbon?) e.emitter.object.add(ribbon);
    await previous.close();
    _updateDemand();
    _context.invalidate();
  });
  Future<void> _frame(FrameInfo frame) => _serial(() async {
    for (final e in _emitters.values) {
      final ticks = e.clock.advance(frame.delta.inMicroseconds / 1000000);
      await e.renderer.update(
        ticks,
        emitter: _world(e.emitter.object),
        camera: _world(_context.camera),
      );
      if (ticks.any((tick) => tick.count > 0)) {
        e.lastEmission = e.clock.tick * e.emitter.settings.fixedStep;
      }
      if (e.clock.playback == ParticlePlayback.draining &&
          e.clock.tick * e.emitter.settings.fixedStep >=
              e.lastEmission + e.emitter.settings.lifetime) {
        e.clock.reset();
        await e.renderer.reset();
      }
    }
    _updateDemand();
  });
  void _updateDemand() {
    final active = _emitters.values.any(
      (e) =>
          e.clock.playback == ParticlePlayback.playing ||
          e.clock.playback == ParticlePlayback.draining,
    );
    if (active) {
      _demand ??= _context.acquireFrameDemand();
    } else {
      _demand?.dispose();
      _demand = null;
    }
  }

  Future<void> _close() async {
    _closed = true;
    _demand?.dispose();
    _demand = null;
    await _queue;
    for (final e in _emitters.values) {
      await e.renderer.close();
      if (e.added) e.emitter.object.parent?.remove(e.emitter.object);
    }
    _emitters.clear();
    await _owner.close();
  }
}

final class _EmitterRuntime {
  final ParticleEmitter emitter;
  ParticleRenderer renderer;
  final ParticleClock clock;
  final bool added;
  double lastEmission = 0;
  _EmitterRuntime(this.emitter, this.renderer, this.added)
    : clock = ParticleClock(emitter.settings);
}

Mat4 _world(Object3D object) {
  var matrix = object.localMatrix;
  for (var parent = object.parent; parent != null; parent = parent.parent) {
    matrix = parent.localMatrix * matrix;
  }
  return matrix;
}
