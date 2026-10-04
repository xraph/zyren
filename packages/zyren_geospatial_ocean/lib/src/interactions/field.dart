import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'emitter.dart';
import 'settings.dart';
import 'field_wgsl.dart';

enum OceanInteractionMode { visualOnly }

/// Persistent native height/foam state over a fixed tangent chart. All writes
/// await exclusive execution. Rendering samples the stable published texture.
final class OceanInteractionField {
  final GpuScope _scope;
  final OceanInteractionSettings settings;
  final OceanInteractionQueue _queue;
  final Vec3 east, north, up;
  Vec3 _anchor;
  final Vec3 referenceAnchorEcef;
  final GpuResource<Buffer> mapping;
  final int substeps, logicalBytes;
  final GpuResource<Texture> texture, foamSources;
  final List<GpuResource<Buffer>> _states, _configs;
  final GpuResource<Buffer> _events;
  final _steps = <CompiledGraph>[],
      _shifts = <CompiledGraph>[],
      _publications = <CompiledGraph>[];
  int _slot = 0, _revision = 0;
  bool _closed = false, _faulted = false;
  Future<void>? _pending, _closing;
  OceanInteractionField._(
    this._scope,
    this.settings,
    this._queue,
    this.east,
    this.north,
    this.up,
    this._anchor,
    this.referenceAnchorEcef,
    this.mapping,
    this.substeps,
    this.logicalBytes,
    this.texture,
    this.foamSources,
    this._states,
    this._configs,
    this._events,
  );
  Vec3 get anchorEcef => _anchor;
  GeoInstant get time => _queue.time;
  int get revision => _revision;
  int get pendingCount => _queue.pendingCount;
  int get sourceCount => _queue.sourceCount;
  bool get isClosed => _closed || _scope.isClosed;
  bool get isFaulted => _faulted;
  bool get isReady => !isClosed && !_faulted && _pending == null;
  OceanInteractionMode get mode => OceanInteractionMode.visualOnly;
  double? get physicalHeightErrorBound => null;
  int get dispatchesPerStep => substeps + 1;
  static int estimateBytes(
    OceanInteractionSettings settings,
    int hz,
    int maxPerTick,
  ) =>
      settings.resolution * settings.resolution * 64 +
      settings.substepsFor(hz) * 80 +
      maxPerTick * 32 +
      16 +
      settings.resolution * 16;

  static Future<OceanInteractionField> create(
    GpuScope parent, {
    required Vec3 anchorEcef,
    required GeoInstant initialTime,
    OceanInteractionSettings? settings,
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
    int maxPending = 256,
    int maxPerTick = 64,
    int maxSources = 128,
    int maxFutureTicks = 600,
    int maxLogicalBytes = 64 * 1024 * 1024,
  }) async {
    final options = settings ?? OceanInteractionSettings();
    final queue = OceanInteractionQueue(
      initialTime: initialTime,
      maxPending: maxPending,
      maxPerTick: maxPerTick,
      maxSources: maxSources,
      maxFutureTicks: maxFutureTicks,
    );
    if (!anchorEcef.isFinite ||
        anchorEcef.length < 1 ||
        anchorEcef.length > 1e12) {
      throw ArgumentError('Invalid interaction anchor.');
    }
    final basis = ellipsoid.eastNorthUpVectors(anchorEcef);
    final steps = options.substepsFor(initialTime.hz), n = options.resolution;
    final bytes = estimateBytes(options, initialTime.hz, maxPerTick);
    if (maxLogicalBytes < 1 ||
        maxLogicalBytes > 1 << 30 ||
        bytes > maxLogicalBytes) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Interaction field exceeds logical byte allowance.',
      );
    }
    final scope = parent.createChild(label: 'ocean-interactions');
    try {
      Future<GpuResource<Buffer>> buffer(int size, {bool uniform = false}) =>
          scope.resources.createBuffer(
            BufferDescriptor(
              size: size,
              usage: {
                if (uniform) BufferUsage.uniform else BufferUsage.storage,
                BufferUsage.copySource,
                BufferUsage.copyDestination,
              },
            ),
          );
      Future<GpuResource<Texture>> image({bool publication = false}) =>
          scope.resources.createTexture(
            TextureDescriptor(
              width: n,
              height: n + (publication ? 1 : 0),
              format: TextureFormat.rgba32Float,
              usage: {
                TextureUsage.sampled,
                TextureUsage.storage,
                TextureUsage.copyDestination,
                TextureUsage.copySource,
              },
            ),
          );
      final states = [await buffer(n * n * 16), await buffer(n * n * 16)];
      final configs = [
        for (var i = 0; i < steps; i++) await buffer(80, uniform: true),
      ];
      final mapping = await buffer(16, uniform: true);
      final eventBuffer = await buffer(maxPerTick * 32),
          output = await image(publication: true),
          sources = await image();
      final value = OceanInteractionField._(
        scope,
        options,
        queue,
        basis.east,
        basis.north,
        basis.up,
        anchorEcef,
        anchorEcef,
        mapping,
        steps,
        bytes,
        output,
        sources,
        states,
        configs,
        eventBuffer,
      );
      final update = await scope.shaders.compile(
        ShaderSource.wgsl(
          oceanInteractionUpdateWgsl,
          label: 'ocean-interaction-update',
        ),
      );
      final shift = await scope.shaders.compile(
        ShaderSource.wgsl(
          oceanInteractionShiftWgsl,
          label: 'ocean-interaction-shift',
        ),
      );
      final publish = await scope.shaders.compile(
        ShaderSource.wgsl(
          oceanInteractionPublishWgsl,
          label: 'ocean-interaction-publish',
        ),
      );
      final work = Workgroups((n + 7) ~/ 8, (n + 7) ~/ 8);
      ComputePassDescriptor publication(int slot, String name) =>
          ComputePassDescriptor(
            name: name,
            program: publish,
            workgroups: work,
            reads: [configs.first, states[slot], mapping],
            writes: [output],
            bindings: ShaderBindings([
              BufferBinding.uniform(0, configs.first),
              BufferBinding.storageRead(1, states[slot]),
              TextureBinding.storage(2, output),
              BufferBinding.uniform(3, mapping),
            ]),
          );
      for (var start = 0; start < 2; start++) {
        final passes = <PassDescriptor>[];
        for (var step = 0; step < steps; step++) {
          final source = (start + step) % 2,
              target = 1 - source,
              config = configs[step];
          passes.add(
            ComputePassDescriptor(
              name: 'interaction-$step',
              program: update,
              workgroups: work,
              reads: [
                config,
                states[source],
                eventBuffer,
                sources,
                states[target],
              ],
              writes: [states[target]],
              bindings: ShaderBindings([
                BufferBinding.uniform(0, config),
                BufferBinding.storageRead(1, states[source]),
                BufferBinding.storageReadWrite(2, states[target]),
                BufferBinding.storageRead(3, eventBuffer),
                TextureBinding.sampled(4, sources),
              ]),
            ),
          );
        }
        passes.add(publication((start + steps) % 2, 'publish'));
        value._steps.add(
          await scope
              .createChild(label: 'interaction-graph')
              .graphs
              .compile(
                GraphDescription(
                  label: 'interaction-step-$start',
                  passes: passes,
                  inputs: [
                    ...states,
                    ...configs,
                    eventBuffer,
                    sources,
                    mapping,
                  ],
                ),
              ),
        );
        value._publications.add(
          await scope
              .createChild(label: 'interaction-graph')
              .graphs
              .compile(
                GraphDescription(
                  label: 'interaction-publish-$start',
                  passes: [publication(start, 'publish')],
                  inputs: [configs.first, states[start], mapping],
                ),
              ),
        );
        value._shifts.add(
          await scope
              .createChild(label: 'interaction-graph')
              .graphs
              .compile(
                GraphDescription(
                  label: 'interaction-shift-$start',
                  passes: [
                    ComputePassDescriptor(
                      name: 'shift',
                      program: shift,
                      workgroups: work,
                      reads: [configs.first, states[start], states[1 - start]],
                      writes: [states[1 - start]],
                      bindings: ShaderBindings([
                        BufferBinding.uniform(0, configs.first),
                        BufferBinding.storageRead(1, states[start]),
                        BufferBinding.storageReadWrite(2, states[1 - start]),
                      ]),
                    ),
                    publication(1 - start, 'publish'),
                  ],
                  inputs: [...states, configs.first, mapping],
                ),
              ),
        );
      }
      await value._clear();
      return value;
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  void _check({bool allowFault = false}) {
    if (isClosed) throw StateError('Interaction field closed.');
    if (_faulted && !allowFault) {
      throw StateError('Reset the failed interaction field before continuing.');
    }
  }

  Future<T> _exclusive<T>(
    Future<T> Function() action, {
    bool allowFault = false,
  }) async {
    _check(allowFault: allowFault);
    if (_pending != null) {
      throw StateError('Await the pending interaction operation.');
    }
    final pending = Completer<void>();
    _pending = pending.future;
    try {
      return await action();
    } finally {
      _pending = null;
      pending.complete();
    }
  }

  OceanInteractionAdmission enqueue(OceanInteraction event) {
    _check();
    if (_pending != null) {
      throw StateError('Cannot enqueue during native field mutation.');
    }
    final delta = event.ecefPosition - _anchor;
    if (delta.dot(east).abs() > settings.extentMetres / 2 ||
        delta.dot(north).abs() > settings.extentMetres / 2) {
      return OceanInteractionAdmission.outsideWindow;
    }
    if (event.radiusMetres < settings.cellMetres * 1.5) {
      return OceanInteractionAdmission.belowResolution;
    }
    return _queue.enqueue(event);
  }

  Float32List _config({
    int count = 0,
    bool inject = false,
    Vec3 flow = Vec3.zero,
    int shiftX = 0,
    int shiftY = 0,
  }) => Float32List.fromList([
    settings.resolution.toDouble(),
    settings.cellMetres,
    1 / (time.hz * substeps),
    settings.waveSpeed,
    settings.damping,
    settings.boundaryDamping,
    settings.absorbingWidthCells.toDouble(),
    settings.maxDisplacementMetres,
    count.toDouble(),
    inject ? 1 : 0,
    settings.foamLifetimeSeconds,
    settings.foamGain,
    flow.dot(east),
    flow.dot(north),
    0,
    0,
    shiftX.toDouble(),
    shiftY.toDouble(),
    0,
    0,
  ]);

  Future<void> step(
    GeoInstant instant, {
    Vec3 foamVelocityEcef = Vec3.zero,
  }) => _exclusive(() async {
    final batch = _queue.peekTick(instant);
    if (!foamVelocityEcef.isFinite ||
        foamVelocityEcef.length > 1000 ||
        foamVelocityEcef.length / (time.hz * substeps * settings.cellMetres) >
            4) {
      throw ArgumentError(
        'Foam transport exceeds four cells per stable substep.',
      );
    }
    final upload = Float32List(_queue.maxPerTick * 8);
    for (var i = 0; i < batch.length; i++) {
      final event = batch[i], delta = event.ecefPosition - _anchor;
      upload.setRange(i * 8, i * 8 + 8, [
        delta.dot(east),
        delta.dot(north),
        event.radiusMetres,
        math.min(settings.maxDisplacementMetres, math.sqrt(event.energy)),
        event.relativeVelocity.dot(east),
        event.relativeVelocity.dot(north),
        0,
        0,
      ]);
    }
    try {
      await _scope.resources.writeBuffer(_events, upload);
      for (var i = 0; i < substeps; i++) {
        await _scope.resources.writeBuffer(
          _configs[i],
          _config(count: batch.length, inject: i == 0, flow: foamVelocityEcef),
        );
      }
      await _steps[_slot].execute();
      _slot = (_slot + substeps) % 2;
      _queue.takeTick(instant);
      _revision++;
    } catch (_) {
      _faulted = true;
      rethrow;
    }
  });

  /// Move by whole tangent-grid cells. Existing values keep their world locations.
  /// Foam source maps are cleared because their old grid mapping is no longer valid.
  Future<void> recenter(Vec3 desiredAnchor) => _exclusive(() async {
    if (!desiredAnchor.isFinite) {
      throw ArgumentError('Invalid interaction center.');
    }
    final delta = desiredAnchor - _anchor, dx = settings.cellMetres;
    final x = (delta.dot(east) / dx).round(),
        y = (delta.dot(north) / dx).round();
    if (x == 0 && y == 0) return;
    if (x.abs() > 1000000 || y.abs() > 1000000) {
      throw ArgumentError('Interaction recenter exceeds bounded travel.');
    }
    try {
      await _scope.resources.writeBuffer(
        _configs.first,
        _config(shiftX: x, shiftY: y),
      );
      final nextAnchor = _anchor + east * (x * dx) + north * (y * dx);
      await _writeMapping(nextAnchor);
      await _shifts[_slot].execute();
      _slot = 1 - _slot;
      await _scope.resources.writeTexture(
        foamSources,
        Float32List(settings.resolution * settings.resolution * 4),
      );
      _anchor = nextAnchor;
      _revision++;
    } catch (_) {
      _faulted = true;
      rethrow;
    }
  });

  /// RG stores nonnegative whitecap and shore emission rates in 1/s. BA is
  /// reserved. A native producer can retain foamSources instead of uploading.
  Future<void> writeFoamSources(Float32List rgba) {
    if (rgba.length != settings.resolution * settings.resolution * 4 ||
        rgba.any((v) => !v.isFinite || v < 0 || v > 1000)) {
      throw ArgumentError('Invalid interaction foam source grid.');
    }
    final copy = Float32List.fromList(rgba);
    return _exclusive(() => _scope.resources.writeTexture(foamSources, copy));
  }

  /// Serialize an externally compiled native producer with field mutations.
  /// The producer must write only foamSources and must not call back into this
  /// field. Failed writes require reset because source contents are uncertain.
  Future<void> updateFoamSources(Future<void> Function() produce) =>
      _exclusive(() async {
        try {
          await produce();
        } catch (_) {
          _faulted = true;
          rethrow;
        }
      });

  Future<void> reset(int generation, {int tick = 0}) => _exclusive(() async {
    if (generation <= time.generation) {
      throw ArgumentError('Reset needs a newer interaction generation.');
    }
    GeoInstant(
      tick: tick,
      hz: time.hz,
      epoch: time.epoch,
      generation: generation,
      standard: time.standard,
    );
    await _clear();
    _queue.reset(generation, tick: tick);
    _faulted = false;
    _revision++;
  }, allowFault: true);
  Future<void> _writeMapping([Vec3? anchor]) => _scope.resources.writeBuffer(
    mapping,
    Float32List.fromList([
      ((anchor ?? _anchor) - referenceAnchorEcef).dot(east),
      ((anchor ?? _anchor) - referenceAnchorEcef).dot(north),
      settings.extentMetres,
      settings.resolution.toDouble(),
    ]),
  );

  Future<void> _clear() async {
    await _writeMapping();
    final zero = Float32List(settings.resolution * settings.resolution * 4);
    for (final buffer in _states) {
      await _scope.resources.writeBuffer(buffer, zero);
    }
    await _scope.resources.writeTexture(foamSources, zero);
    await _scope.resources.writeBuffer(_configs.first, _config());
    _slot = 0;
    await _publications.first.execute();
  }

  /// Explicit diagnostic readback, absent from the render/simulation path.
  Future<Float32List> debugState() => _exclusive(() async {
    final data = await _scope.resources.readBuffer(_states[_slot]);
    return Float32List.fromList(
      data.buffer.asFloat32List(data.offsetInBytes, data.lengthInBytes ~/ 4),
    );
  });
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _pending;
    await _scope.close();
  }
}
