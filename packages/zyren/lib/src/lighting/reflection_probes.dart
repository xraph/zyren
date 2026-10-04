import 'dart:async';
import 'dart:math' as math;
import '../math/vec3.dart';
import '../plugins/attachment_scope.dart';
import '../scene/scene.dart';
import '../spatial/bounds.dart';
import '../rendering/render_backend.dart';
import '../rendering/frame_submission.dart';
import '../rendering/frame_output.dart';
import '../resources/resource_scope.dart';
import '../resources/texture.dart';
part 'reflection_probe_shader.dart';

/// One capture point and its world-space selection bounds. Reflections use the
/// capture point without parallax correction. Selection changes at object-anchor
/// boundaries; use overlapping bounds and priority to control those transitions.
final class ReflectionProbeDescriptor {
  final int id, priority, faceSize;
  final Vec3 position;
  final Bounds3 bounds;
  final double near, far;
  final EnvironmentQuality quality;
  ReflectionProbeDescriptor({
    required this.id,
    required this.position,
    required this.bounds,
    this.priority = 0,
    this.faceSize = 32,
    this.near = .1,
    this.far = 1000,
    this.quality = const EnvironmentQuality(
      specularWidth: 64,
      diffuseWidth: 16,
      brdfSize: 32,
      samples: 64,
    ),
  }) {
    if (id < 0 ||
        !position.isFinite ||
        !bounds.contains(position) ||
        faceSize < 16 ||
        faceSize > 256 ||
        faceSize & (faceSize - 1) != 0 ||
        !near.isFinite ||
        !far.isFinite ||
        near <= 0 ||
        far <= near) {
      throw ArgumentError(
        'Probe requires finite bounds, a contained capture point, and power-of-two faces in [16,256].',
      );
    }
    quality.validate();
    for (final count in [
      quality.diffuseWidth * quality.diffuseWidth ~/ 2,
      quality.brdfSize * quality.brdfSize,
      for (var i = 0; i < quality.specularMipLevels; i++)
        (quality.specularWidth >> i) * (quality.specularWidth >> i) ~/ 2,
    ]) {
      if (count * quality.samples > ReflectionProbes.maxIntegrationSamples) {
        throw ArgumentError(
          'A probe filtering job exceeds 16,777,216 samples.',
        );
      }
    }
  }
  int get mapBytes =>
      8 *
      (quality.diffuseWidth * quality.diffuseWidth ~/ 2 +
          quality.brdfSize * quality.brdfSize +
          [
            for (var i = 0; i < quality.specularMipLevels; i++)
              (quality.specularWidth >> i) * (quality.specularWidth >> i) ~/ 2,
          ].fold(0, (a, b) => a + b));
  int get candidateBytes =>
      mapBytes +
      faceSize * faceSize * 8 * (6 + 8) +
      16 * (quality.specularMipLevels + 2);
}

final class _PublishedProbe {
  final ReflectionProbeDescriptor descriptor;
  final Environment environment;
  final int contentRevision;
  _PublishedProbe(this.descriptor, EnvironmentMap map, this.contentRevision)
    : environment = Environment(map: map);
}

/// Four local environments with one candidate and one GPU job per [advance].
/// Attach this collection to Scene.reflectionProbes for automatic PBR selection.
/// Keep requesting frames while [pending] is true. Multiple collections share
/// the native resource budget and the device's four capture-lease limit.
final class ReflectionProbes {
  static const maxStorageBytes = 33554432;
  static const maxIntegrationSamples = 16777216;
  final GraphBackend _backend;
  final ResourceScope _scope;
  final SceneCaptureView _capture;
  final Map<int, _PublishedProbe> _published = {};
  final _retirements = <Object, ResourceRetirement>{};
  final _retiredGenerations = <Set<Object>>[];
  Iterable<EnvironmentMap> get _ownedMaps =>
      _published.values.map((p) => p.environment.map);
  _ProbeCandidate? _candidate;
  bool _closed = false, _advancing = false;
  Future<void>? _starting, _closing;
  int _generation = 0;
  Completer<void>? _advanceDone;
  SceneCaptureReceipt? lastCapture;
  int completedJobs = 0, lastIntegrationSamples = 0;
  Object? lastError;
  ReflectionProbes._(this._backend, this._scope, this._capture);
  static Future<ReflectionProbes> create(GraphBackend backend) async {
    if (backend is! CaptureBackend) {
      throw UnsupportedError('Backend has no GPU scene capture.');
    }
    final capture = await (backend as CaptureBackend).createCaptureView();
    return ReflectionProbes._(
      backend,
      backend.createResourceScope(label: 'local reflection probes'),
      capture,
    );
  }

  void configureCaptureUploadBudget(int bytes) =>
      _capture.configureSceneUploadBudget(bytes);
  bool get pending => _candidate != null || _starting != null;
  int get count => _published.length;
  int get captureFaces => _candidate?.face ?? 0;
  int get retainedGenerations => _retiredGenerations.length;
  int get _retainedBytes {
    final sizes = <Object, int>{};
    for (final map in _ownedMaps) {
      for (final t in [map.diffuse, map.specular, map.brdf]) {
        sizes[t.allocationIdentity] = t.descriptor.byteLength;
      }
    }
    for (final ticket in _retirements.values) {
      sizes[ticket.allocationIdentity] = ticket.byteLength;
    }
    return sizes.values.fold(0, (a, b) => a + b);
  }

  int get storageBytes =>
      _retainedBytes +
      (_candidate?.descriptor.candidateBytes ?? 0) +
      (_candidate?.inputBytes ?? 0);
  Future<void> reclaim() async {
    for (final ticket in _retirements.values.toList()) {
      if (await ticket.poll()) _retirements.remove(ticket.allocationIdentity);
    }
    // Shared BRDF tickets remain charged independently after unique outputs end.
    _retiredGenerations.removeWhere(
      (keys) => !keys.any(_retirements.containsKey),
    );
  }

  Future<void> _prepareRetirement(EnvironmentMap map) async {
    final created = <ResourceRetirement>[];
    try {
      for (final t in [map.diffuse, map.specular, map.brdf]) {
        if (!_retirements.containsKey(t.allocationIdentity)) {
          final ticket = await t.watchRetirement();
          created.add(ticket);
          _retirements[t.allocationIdentity] = ticket;
        }
      }
    } catch (_) {
      for (final t in created) {
        _retirements.remove(t.allocationIdentity);
        await t.close();
      }
      rethrow;
    }
  }

  int? revision(int id) => _published[id]?.contentRevision;
  Environment? environment(int id) => _published[id]?.environment;

  /// Bounds and distance use double world coordinates before the renderer shifts
  /// its origin. Each material receives one map; no per-pixel blend is implied.
  Environment? select(Vec3 worldAnchor) {
    _PublishedProbe? chosen;
    for (final probe in _published.values) {
      if (!probe.descriptor.bounds.contains(worldAnchor)) continue;
      if (chosen == null ||
          probe.descriptor.priority > chosen.descriptor.priority ||
          (probe.descriptor.priority == chosen.descriptor.priority &&
              (probe.descriptor.position - worldAnchor).length2 <
                  (chosen.descriptor.position - worldAnchor).length2)) {
        chosen = probe;
      }
    }
    return chosen?.environment;
  }

  /// Captures all six immutable CPU submissions now. Camera motion in another
  /// view does not invalidate this cycle. Pass a new contentRevision when scene
  /// content changes. Caller-owned mutable GPU textures and shader uniforms stay
  /// live; pause their writes if you need a consistent capture across six steps.
  /// Main-view postprocess graphs are excluded. Global environment lighting is
  /// retained, while clear/composition is opaque and local probes are excluded.
  Future<void> update(
    ReflectionProbeDescriptor descriptor, {
    required Scene scene,
    required int contentRevision,
    Environment? environment,
  }) {
    if (_closed) {
      return Future.error(StateError('Reflection probes have closed.'));
    }
    if (_starting != null || _advancing) {
      return Future.error(StateError('Probe work is already in flight.'));
    }
    final generation = ++_generation;
    final work = _update(
      descriptor,
      scene,
      contentRevision,
      environment,
      generation,
    );
    _starting = work;
    return work.whenComplete(() => _starting = null);
  }

  Future<void> _update(
    ReflectionProbeDescriptor d,
    Scene scene,
    int revision,
    Environment? environment,
    int generation,
  ) async {
    if (revision < 0) throw ArgumentError.value(revision, 'contentRevision');
    if (!_published.containsKey(d.id) && _published.length >= 4) {
      throw StateError('A collection supports four probes.');
    }
    await reclaim();
    if (_retiredGenerations.length >= 64) {
      throw StateError(
        'Probe generations remain borrowed; retry after their views advance.',
      );
    }
    final volume = scene.environment;
    final inputBytes =
        (environment == null
            ? 0
            : EnvironmentMap.retainedPayloadBytes([environment.map])) +
        (volume == null
            ? 0
            : [
                volume.irradiance,
                volume.specular,
                volume.brdf,
              ].fold<int>(0, (n, t) => n + t.descriptor.byteLength));
    final wanted = _retainedBytes + d.candidateBytes + inputBytes;
    if (wanted > maxStorageBytes) {
      throw StateError('Probe storage exceeds 33,554,432 bytes.');
    }
    await _cancelCandidate();
    if (_closed || generation != _generation) {
      throw StateError('Probe update was cancelled.');
    }
    final owner = _scope.createChild(label: 'probe candidate');
    final c = _ProbeCandidate(d, revision, owner, generation)
      ..inputBytes = inputBytes;
    try {
      Environment? heldEnvironment;
      if (environment != null) {
        heldEnvironment = Environment(
          map: await environment.map.retain(owner),
          intensity: environment.intensity,
          rotation: environment.rotation,
        );
      }
      VolumeEnvironmentMap? heldVolume;
      if (volume != null) {
        heldVolume = VolumeEnvironmentMap(
          irradiance: await owner.retain(volume.irradiance),
          specular: await owner.retain(volume.specular),
          brdf: await owner.retain(volume.brdf),
          intensity: volume.intensity,
          rotation: volume.rotation,
        );
      }
      for (final (direction, up) in _faceAxes) {
        c.frames.add(
          FrameSubmission.capture(
            scene: scene,
            camera: PerspectiveCamera(
              position: d.position,
              target: d.position + direction,
              up: up,
              fieldOfView: math.pi / 2,
              near: d.near,
              far: d.far,
            ),
            size: PhysicalSize(d.faceSize, d.faceSize),
            environment: heldEnvironment,
            radianceCapture: true,
            captureVolumeEnvironment: heldVolume,
          ),
        );
      }
      for (var face = 0; face < 6; face++) {
        c.faces.add(
          await owner.createTexture(
            TextureDescriptor(
              label: 'probe capture face',
              width: d.faceSize,
              height: d.faceSize,
              format: TextureFormat.rgba16Float,
              usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
            ),
          ),
        );
      }
      c.source = await owner.createTexture(
        TextureDescriptor(
          label: 'probe equirectangular radiance',
          width: d.faceSize * 4,
          height: d.faceSize * 2,
          format: TextureFormat.rgba16Float,
          usage: {TextureUsage.sampled, TextureUsage.storage},
        ),
      );
      if (_closed || generation != _generation) {
        throw StateError('Probe update was cancelled.');
      }
      _candidate = c;
      completedJobs = 0;
      lastError = null;
    } catch (_) {
      await owner.close();
      rethrow;
    }
  }

  /// Queues one face, conversion or convolution job. False means no work remains.
  /// A staged scene upload does not advance the face counter.
  Future<bool> advance() async {
    if (_closed) throw StateError('Reflection probes have closed.');
    if (_advancing || _starting != null) {
      throw StateError('Probe work is already in flight.');
    }
    final c = _candidate;
    if (c == null) return false;
    _advancing = true;
    _advanceDone = Completer<void>();
    try {
      if (c.face < 6) {
        lastIntegrationSamples = 0;
        lastCapture = await _capture.capture(c.frames[c.face], c.faces[c.face]);
        if (lastCapture!.admission.candidateReady) {
          c.face++;
          completedJobs++;
        }
      } else if (c.filter == null) {
        await _convert(c);
        completedJobs++;
        _beginFilter(c);
        await c.checkpoint.future;
      } else {
        c.checkpoint = Completer<void>();
        lastIntegrationSamples = c.nextSamples;
        c.permit!.complete();
        await c.checkpoint.future;
        completedJobs++;
      }
      if (c.error != null) Error.throwWithStackTrace(c.error!, c.stack!);
      if (c.result != null) {
        if (c.generation != _generation || _closed) {
          throw StateError('Probe update was cancelled.');
        }
        final old = _published[c.descriptor.id];
        if (old != null) await _prepareRetirement(old.environment.map);
        if (c.generation != _generation || _closed) {
          throw StateError('Probe update was cancelled.');
        }
        _published[c.descriptor.id] = _PublishedProbe(
          c.descriptor,
          c.result!,
          c.revision,
        );
        c.result = null;
        _candidate = null;
        if (old != null) {
          _retiredGenerations.add({
            old.environment.map.diffuse.allocationIdentity,
            old.environment.map.specular.allocationIdentity,
          });
          await old.environment.map.close();
        }
        await c.close();
        await _capture.clear();
        await reclaim();
      }
      return pending;
    } catch (error) {
      lastError = error;
      if (identical(_candidate, c)) _candidate = null;
      await c.close();
      await _capture.clear();
      rethrow;
    } finally {
      _advancing = false;
      _advanceDone!.complete();
    }
  }

  Future<void> _convert(_ProbeCandidate c) async {
    final shaders = _backend.createShaderCompiler(label: 'probe conversion');
    final graphs = _backend.createGraphCompiler(label: 'probe conversion');
    try {
      final shader = await shaders.compile(ShaderSource.wgsl(_probeConversion));
      lastIntegrationSamples =
          c.descriptor.faceSize * c.descriptor.faceSize * 8;
      if (lastIntegrationSamples > maxIntegrationSamples) {
        throw StateError('Probe conversion exceeds its budget.');
      }
      final graph = await graphs.compile(
        GraphDescription(
          inputs: c.faces,
          passes: [
            ComputePassDescriptor(
              name: 'probe panorama',
              program: shader,
              workgroups: Workgroups(
                c.descriptor.faceSize * 4 ~/ 8,
                c.descriptor.faceSize * 2 ~/ 8,
              ),
              reads: c.faces,
              writes: [c.source!],
              bindings: ShaderBindings([
                for (var i = 0; i < 6; i++)
                  TextureBinding.sampled(i, c.faces[i]),
                SamplerBinding(6),
                TextureBinding.storage(7, c.source!),
              ]),
            ),
          ],
        ),
      );
      await graph.execute();
    } finally {
      await graphs.close();
      await shaders.close();
    }
  }

  void _beginFilter(_ProbeCandidate c) {
    GpuResource<Texture>? brdf;
    for (final p in _published.values) {
      if (p.descriptor.quality.brdfSize == c.descriptor.quality.brdfSize &&
          p.descriptor.quality.samples == c.descriptor.quality.samples) {
        brdf = p.environment.map.brdf;
        break;
      }
    }
    c.filter =
        EnvironmentMap.prefilter(
          c.source!,
          resources: _scope,
          quality: c.descriptor.quality,
          reuseBrdf: brdf,
          beforePass: (samples) {
            if (samples > maxIntegrationSamples) {
              throw StateError('Probe filtering exceeds its sample budget.');
            }
            c.nextSamples = samples;
            if (c.cancelled) throw StateError('Probe update was cancelled.');
            c.permit = Completer<void>();
            c.checkpoint.complete();
            return c.permit!.future;
          },
        ).then<void>(
          (map) {
            c.result = map;
            c.checkpoint.complete();
          },
          onError: (Object error, StackTrace stack) {
            c.error = error;
            c.stack = stack;
            if (!c.checkpoint.isCompleted) c.checkpoint.complete();
          },
        );
  }

  Future<void> cancel() async {
    ++_generation;
    try {
      await _starting;
    } catch (_) {
      /* Cancelled initialization drains its candidate. */
    }
    await _cancelCandidate();
  }

  Future<void> _cancelCandidate() async {
    final c = _candidate;
    _candidate = null;
    await _advanceDone?.future;
    await c?.close();
    if (c != null) await _capture.clear();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    ++_generation;
    try {
      await _starting;
    } catch (_) {
      /* Initialization drains its owner. */
    }
    await _advanceDone?.future;
    try {
      await _drainProbeCleanup([
        cancel,
        _capture.close,
        _scope.close,
        for (final ticket in _retirements.values.toList()) ticket.close,
      ]);
    } finally {
      _retirements.clear();
      _retiredGenerations.clear();
      _published.clear();
    }
  }
}

final class _ProbeCandidate {
  final ReflectionProbeDescriptor descriptor;
  final int revision, generation;
  final ResourceScope owner;
  final frames = <FrameSubmission>[];
  final faces = <GpuResource<Texture>>[];
  GpuResource<Texture>? source;
  int face = 0, inputBytes = 0, nextSamples = 0;
  bool cancelled = false;
  Completer<void> checkpoint = Completer<void>();
  Completer<void>? permit;
  Future<void>? filter;
  EnvironmentMap? result;
  Object? error;
  StackTrace? stack;
  Future<void>? _closing;
  _ProbeCandidate(this.descriptor, this.revision, this.owner, this.generation);
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    cancelled = true;
    if (permit != null && !permit!.isCompleted) {
      permit!.completeError(StateError('Probe update was cancelled.'));
    }
    await _drainProbeCleanup([
      () async {
        await filter;
      },
      () async {
        try {
          await result?.close();
        } finally {
          result = null;
        }
      },
      owner.close,
    ]);
  }
}

Future<void> _drainProbeCleanup(
  Iterable<Future<void> Function()> actions,
) async {
  final errors = <Object>[];
  StackTrace? firstStack;
  for (final action in actions) {
    try {
      await action();
    } catch (error, stack) {
      errors.add(error);
      firstStack ??= stack;
    }
  }
  if (errors.isNotEmpty) {
    Error.throwWithStackTrace(ScopeCleanupException(errors), firstStack!);
  }
}

const _faceAxes = [
  (Vec3(1, 0, 0), Vec3(0, 1, 0)),
  (Vec3(-1, 0, 0), Vec3(0, 1, 0)),
  (Vec3(0, 1, 0), Vec3(0, 0, -1)),
  (Vec3(0, -1, 0), Vec3(0, 0, 1)),
  (Vec3(0, 0, 1), Vec3(0, 1, 0)),
  (Vec3(0, 0, -1), Vec3(0, 1, 0)),
];
