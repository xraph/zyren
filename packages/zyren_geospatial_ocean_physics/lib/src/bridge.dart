import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_physics/zyren_physics.dart';
part 'binding.dart';

/// Explicit sleep approximation. Set all thresholds to zero for strict response.
/// Sleeping bodies remain asleep only while gravity and water loads balance.
final class OceanSleepSettings {
  final double linearAcceleration, angularAcceleration, waterSpeed;
  OceanSleepSettings({
    this.linearAcceleration = .02,
    this.angularAcceleration = .02,
    this.waterSpeed = .02,
  }) {
    if ([
      linearAcceleration,
      angularAcceleration,
      waterSpeed,
    ].any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw ArgumentError('Ocean sleep thresholds must be in [0,1].');
    }
  }
}

final class OceanBodyForces {
  final PhysicsBody body;
  final BodyState state;
  final BuoyancyLoads loads;
  final bool preserveSleep, wake;
  const OceanBodyForces._(
    this.body,
    this.state,
    this.loads,
    this.preserveSleep,
    this.wake,
  );
}

/// Prepared commands retain the exact world, source, frame, binding and tick.
final class OceanForceBatch {
  final OceanPhysicsBridge _owner;
  final int _worldRevision, _bindingRevision, _frameRevision;
  final String _coverageRevision;
  final String? _currentRevision;
  final GeoInstant instant;
  final List<OceanBodyForces> bodies;
  final Vec3 gravity;
  final String seaStateRevision;
  OceanForceBatch._(
    this._owner,
    this._worldRevision,
    this._bindingRevision,
    this._frameRevision,
    this._coverageRevision,
    this._currentRevision,
    this.instant,
    List<OceanBodyForces> bodies,
    this.gravity,
    this.seaStateRevision,
  ) : bodies = List.unmodifiable(bodies);
}

/// Borrows an existing world and sampler. The existing owner advances physics.
/// One bridge owns the water bindings for a world; it never owns scene transforms.
final class OceanPhysicsBridge {
  static final _owners = Expando<OceanPhysicsBridge>('ocean physics bridge');
  final PhysicsWorld world;
  final OceanSampler sampler;
  final OceanQueryPolicy policy;

  /// Optional fluid transport velocity in body-fixed ECEF axes, in m/s.
  /// This adds current velocity to drag without advecting the spectral surface.
  final GeoFieldSource<Vec3>? current;
  final double density;
  final int maxBodies;
  final Map<PhysicsBody, _Binding> _bindings = {};
  int _bindingRevision = 0;
  int _frameRevision;
  bool _closed = false;
  Completer<void>? _pending;
  Future<void>? _closing;
  OceanForceBatch? _prepared;
  PhysicsForceBatch? _queued;
  int? _queuedStep;
  GeoInstant? _lastApplied;
  Object? lastFailure;
  OceanPhysicsBridge({
    required this.world,
    required this.sampler,
    required this.policy,
    double? density,
    this.current,
    this.maxBodies = 64,
  }) : density = density ?? sampler.state.density,
       _frameRevision = sampler.frame.revision {
    if (world.isClosed || _owners[world] != null) {
      throw StateError(
        'Physics world is closed or already has an ocean bridge.',
      );
    }
    if (!this.density.isFinite ||
        this.density <= 0 ||
        this.density > 1e6 ||
        maxBodies < 1 ||
        maxBodies > 1024) {
      throw ArgumentError('Invalid ocean body or density limits.');
    }
    _owners[world] = this;
  }
  bool get isClosed => _closed;
  int get bindingCount => _bindings.length;
  GeoInstant? get lastApplied => _lastApplied;
  void _check() {
    if (_closed || world.isClosed) {
      throw StateError('Ocean physics bridge is closed.');
    }
    if (_frameRevision != sampler.frame.revision) {
      throw StateError(
        'Apply the world frame rebase before preparing water loads.',
      );
    }
  }

  Registration bind(
    PhysicsBody body,
    BuoyancyShape shape, {
    BuoyancySolver? solver,
    double? density,
    OceanSleepSettings? sleep,
  }) {
    _check();
    if (!identical(body.world, world) ||
        _bindings.containsKey(body) ||
        _bindings.length >= maxBodies) {
      throw ArgumentError(
        'Body is foreign, already bound or exceeds the binding budget.',
      );
    }
    final state = body.state, waterDensity = density ?? this.density;
    if (state.kind != BodyKind.dynamic ||
        state.mass <= 0 ||
        !state.mass.isFinite ||
        !waterDensity.isFinite ||
        waterDensity <= 0 ||
        waterDensity > 1e6) {
      throw ArgumentError(
        'Buoyancy requires a dynamic body with current mass and valid water density.',
      );
    }
    final points =
        shape.quadraturePoints.length +
        _bindings.values.fold(0, (n, b) => n + b.shape.quadraturePoints.length);
    if (points > policy.maxSamples || points > sampler.limits.maxSamples) {
      throw ArgumentError(
        'Body quadrature exceeds the shared physical sample budget.',
      );
    }
    final binding = _Binding(
      body,
      shape,
      solver ?? BuoyancySolver(),
      waterDensity,
      sleep ?? OceanSleepSettings(),
    );
    _bindings[body] = binding;
    _bindingRevision++;
    _prepared = null;
    return Registration(() {
      if (identical(_bindings[body], binding)) {
        if (_queuedStep == world.completedSteps) _queued?.removeBody(body);
        _bindings.remove(body);
        _bindingRevision++;
        _prepared = null;
      }
    });
  }

  void _instant(GeoInstant instant) {
    if ((world.fixedStep - 1 / instant.hz).abs() > 1e-12 ||
        sampler.now() != instant) {
      throw StateError(
        'Water preparation must use the current shared physics tick.',
      );
    }
    if (_queuedStep == world.completedSteps) {
      throw StateError(
        'Integrate the accepted water forces before preparing another tick.',
      );
    }
    final last = _lastApplied;
    if (last != null &&
        (!instant.sameTimeline(last) || instant.tick != last.tick + 1)) {
      throw StateError(
        'Ocean physics ticks must advance once on the same timeline.',
      );
    }
  }

  Future<OceanForceBatch> prepare(GeoInstant instant) async {
    _check();
    _instant(instant);
    if (_pending != null) {
      throw StateError('Ocean force preparation is already pending.');
    }
    final pending = _pending = Completer<void>();
    _prepared = null;
    try {
      final worldRevision = world.revision,
          bindingRevision = _bindingRevision,
          frameRevision = _frameRevision;
      final currentRevision = current?.revision;
      final sourceRevision = sampler.coverage.revision, gravity = world.gravity;
      final work =
          <(_Binding, BodyState, BuoyancyBodyState, List<OceanQuery>)>[];
      final queries = <OceanQuery>[];
      for (final binding in _bindings.values) {
        final state = binding.body.state, inertia = state.inverseInertia;
        final body = BuoyancyBodyState(
          frame: sampler.frame,
          time: instant,
          position: state.pose.position,
          rotation: state.pose.rotation,
          centerOfMass: state.centerOfMass,
          linearVelocity: state.velocity,
          angularVelocity: state.angularVelocity,
          mass: state.mass,
          inverseInertia: BuoyancyInverseInertia(
            inertia.xx,
            inertia.yy,
            inertia.zz,
            xy: inertia.xy,
            xz: inertia.xz,
            yz: inertia.yz,
          ),
        );
        final points = binding.solver.queries(body, binding.shape);
        queries.addAll(points);
        work.add((binding, state, body, points));
      }
      var samples = queries.isEmpty
          ? <OceanSample>[]
          : await sampler.sampleBatch(queries, policy);
      if (current case final provider?) {
        final combined = <OceanSample>[];
        // Bound concurrent provider work; Future.wait drains each accepted group.
        for (var start = 0; start < samples.length; start += 16) {
          final end = (start + 16).clamp(0, samples.length);
          combined.addAll(
            await Future.wait([
              for (final sample in samples.sublist(start, end))
                _withCurrent(sample, provider, currentRevision!),
            ]),
          );
        }
        samples = combined;
      }
      _check();
      _instant(instant);
      if (world.revision != worldRevision ||
          _bindingRevision != bindingRevision ||
          _frameRevision != frameRevision ||
          sampler.coverage.revision != sourceRevision ||
          current?.revision != currentRevision) {
        throw StateError(
          'World, bindings, frame or water coverage changed during preparation.',
        );
      }
      final bodies = <OceanBodyForces>[];
      var offset = 0;
      for (final (binding, state, body, points) in work) {
        final part = samples.sublist(offset, offset + points.length);
        offset += points.length;
        final loads = binding.solver.solve(
          body,
          binding.shape,
          part,
          gravity: gravity,
          density: binding.density,
          stepSeconds: world.fixedStep,
        );
        final balanced =
            (loads.totalForce / body.mass + gravity).length <=
                binding.sleep.linearAcceleration &&
            body.inverseInertia.apply(loads.totalTorque).length <=
                binding.sleep.angularAcceleration &&
            part.every(
              (s) => s.value!.velocityLocal.length <= binding.sleep.waterSpeed,
            );
        bodies.add(
          OceanBodyForces._(
            binding.body,
            state,
            loads,
            state.sleeping && balanced,
            !balanced,
          ),
        );
      }
      final batch = OceanForceBatch._(
        this,
        worldRevision,
        bindingRevision,
        frameRevision,
        sourceRevision,
        currentRevision,
        instant,
        bodies,
        gravity,
        sampler.state.revision,
      );
      _prepared = batch;
      lastFailure = null;
      return batch;
    } catch (error) {
      lastFailure = error;
      rethrow;
    } finally {
      _pending = null;
      pending.complete();
    }
  }

  Future<OceanSample> _withCurrent(
    OceanSample sample,
    GeoFieldSource<Vec3> provider,
    String revision,
  ) async {
    if (!sample.available) return sample;
    final water = sample.value!, accuracy = sample.accuracy!;
    final coordinate = sampler.frame.reference.ellipsoid.fromEcef(
      water.positionEcef,
    );
    final flow = await provider.sample(coordinate, sample.query.time);
    if (provider.units != 'm/s' ||
        flow.units != 'm/s' ||
        flow.error == null ||
        !flow.isCurrent(
          frameId: 'body-fixed',
          frameRevision: 0,
          sourceRevision: revision,
          time: sample.query.time,
          maximumAge: Duration.zero,
        ) ||
        !flow.value!.isFinite ||
        flow.value!.length > 1000) {
      throw StateError(
        'Ocean current is unavailable, stale or lacks bounded ECEF velocity.',
      );
    }
    final velocity = water.velocityEcef + flow.value!;
    final velocityError = accuracy.velocityErrorMetresPerSecond + flow.error!;
    if (!velocityError.isFinite ||
        velocityError > policy.maxVelocityErrorMetresPerSecond) {
      throw StateError(
        'Combined wave and current velocity exceeds the query accuracy policy.',
      );
    }
    return OceanSample(
      query: sample.query,
      failure: null,
      value: OceanSurfaceValue(
        positionEcef: water.positionEcef,
        materialEcef: water.materialEcef,
        normalEcef: water.normalEcef,
        velocityEcef: velocity,
        positionLocal: water.positionLocal,
        normalLocal: water.normalLocal,
        velocityLocal: sampler.frame.vectorToLocal(velocity),
        height: water.height,
      ),
      accuracy: OceanSurfaceAccuracy(
        accuracy.heightErrorMetres,
        accuracy.normalErrorRadians,
        velocityError,
        accuracy.rootRadiusMetres,
      ),
      seaStateRevision: sample.seaStateRevision,
      coverageRevision: sample.coverageRevision,
      frameId: sample.frameId,
      frameRevision: sample.frameRevision,
      evaluatedTime: sample.evaluatedTime,
      age: sample.age,
      residual: sample.residual,
    );
  }

  void apply(OceanForceBatch batch, double stepSeconds) {
    _check();
    if (!identical(batch._owner, this) ||
        !identical(_prepared, batch) ||
        _pending != null ||
        world.revision != batch._worldRevision ||
        _bindingRevision != batch._bindingRevision ||
        _frameRevision != batch._frameRevision ||
        sampler.coverage.revision != batch._coverageRevision ||
        current?.revision != batch._currentRevision) {
      throw StateError(
        'Prepared ocean batch is stale, foreign or already applied.',
      );
    }
    _instant(batch.instant);
    if (!stepSeconds.isFinite ||
        (stepSeconds - world.fixedStep).abs() > 1e-12) {
      throw ArgumentError(
        'Ocean impulse duration must equal the existing physics step.',
      );
    }
    final commands = <PhysicsForce>[];
    for (final body in batch.bodies) {
      if (body.preserveSleep) continue;
      final points = body.loads.points;
      for (var i = 0; i < points.length; i++) {
        final point = points[i];
        commands.add(
          PhysicsForce(
            body.body,
            force: point.force,
            at: point.position,
            torque: i == 0 ? body.loads.intrinsicTorque : Vec3.zero,
            wake: body.wake,
          ),
        );
      }
      // Dry sleeping bodies must wake when gravity is no longer balanced.
      if (points.isEmpty && body.state.sleeping && body.wake) {
        commands.add(PhysicsForce(body.body, wake: true));
      }
    }
    _queued = world.queueForces(
      commands,
      expectedRevision: batch._worldRevision,
    );
    _queuedStep = world.completedSteps;
    _prepared = null;
    _lastApplied = batch.instant;
  }

  /// Call from GeoWorldFrame.rebases, before its new revision publishes, or
  /// immediately after rebasing and before any simulation step. Once per event.
  void applyRebase(GeoWorldRebase event) {
    if (_closed ||
        world.isClosed ||
        event.frameId != sampler.frame.id ||
        event.previousRevision != _frameRevision ||
        event.revision != _frameRevision + 1 ||
        (sampler.frame.revision != event.previousRevision &&
            sampler.frame.revision != event.revision)) {
      throw StateError('Ocean rebase does not match the current world frame.');
    }
    final m = event.oldToNew.storage;
    final x = Vec3(m[0], m[1], m[2]),
        y = Vec3(m[4], m[5], m[6]),
        z = Vec3(m[8], m[9], m[10]);
    if (m.any((v) => !v.isFinite) ||
        m[3] != 0 ||
        m[7] != 0 ||
        m[11] != 0 ||
        m[15] != 1 ||
        (x.length2 - 1).abs() > 1e-8 ||
        (y.length2 - 1).abs() > 1e-8 ||
        (z.length2 - 1).abs() > 1e-8 ||
        x.dot(y).abs() > 1e-8 ||
        x.dot(z).abs() > 1e-8 ||
        y.dot(z).abs() > 1e-8 ||
        x.cross(y).dot(z) < 1 - 1e-8) {
      throw ArgumentError(
        'Ocean physics frame changes must be proper rigid transforms.',
      );
    }
    final position = Vec3.zero.toVectorMath(),
        rotation = Quat.identity.toVectorMath(),
        scale = Vec3.one.toVectorMath();
    event.oldToNew.toVectorMath().decompose(position, rotation, scale);
    if ((Vec3.fromVectorMath(scale) - Vec3.one).length > 1e-8) {
      throw ArgumentError('Ocean physics frame changes must be rigid.');
    }
    world.rebase(
      PhysicsPose(
        position: Vec3.fromVectorMath(position),
        rotation: Quat.fromVectorMath(rotation),
      ),
      expectedRevision: world.revision,
    );
    _frameRevision = event.revision;
    _bindingRevision++;
    _prepared = null;
  }

  /// Clear water state after the owner restores physics and its shared clock.
  /// Old body handles are invalid; bind the newly reacquired handles afterwards.
  void beginReplay(GeoInstant checkpoint) {
    _check();
    if (_pending != null) {
      throw StateError('Drain pending ocean preparation before replay.');
    }
    final last = _lastApplied;
    if (last != null &&
        (checkpoint.generation <= last.generation ||
            checkpoint.hz != last.hz ||
            checkpoint.epoch != last.epoch ||
            checkpoint.standard != last.standard)) {
      throw ArgumentError(
        'Ocean replay needs a newer generation on the same time standard.',
      );
    }
    _queued?.dispose();
    _queued = null;
    _queuedStep = null;
    _bindings.clear();
    _bindingRevision++;
    _prepared = null;
    _lastApplied = checkpoint;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_queuedStep == world.completedSteps) _queued?.dispose();
    _queued = null;
    _closed = true;
    _bindingRevision++;
    _prepared = null;
    _bindings.clear();
    await _pending?.future;
    if (identical(_owners[world], this)) _owners[world] = null;
  }
}
