import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean_physics/zyren_geospatial_ocean_physics.dart';
import 'package:zyren_particles/zyren_particles.dart';
import 'package:zyren_particles/ocean.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'coast_store.dart';
import 'definition.dart';
import 'geometry.dart';
import 'fog.dart';

final class OceanLabWorld {
  final OceanLabSceneDefinition definition;
  final OceanCoastSource coast;
  final Scene scene = Scene()
    ..renderSettings = RenderSettings(
      hdr: true,
      sampleCount: 1,
      toneMapping: ToneMapping.aces,
    );
  final PerspectiveCamera camera = PerspectiveCamera(
    near: .1,
    far: 4e7,
    depthStrategy: DepthStrategy.reversed,
  );
  final ParticlePlugin particles = ParticlePlugin(emitters: []);
  late final GlobeControlsPlugin navigation;
  late final AtmosphereExtension sky;
  late final OceanExtension ocean;
  late final GeospatialPlugin host;
  late final _LabClock _clockPlugin;
  late final OceanLabLocalGroup local;
  OceanNativePresentation? presentation;
  OceanLabDetail detail;
  OceanWaterDebug debug;
  final GeoDistanceFog? fog;
  bool paused = false, route = false;
  OceanSample? lastQuery;
  OceanInteractionAdmission? lastWakeAdmission;
  Object? simulationFailure;
  OceanLabWorld(
    this.definition,
    this.coast, {
    this.detail = OceanLabDetail.balanced,
    this.debug = OceanWaterDebug.color,
    OceanLabFog fog = OceanLabFog.off,
  }) : fog = definition.hasUnderwater || definition.id == 'orbit'
           ? null
           : fog.settings {
    local = OceanLabLocalGroup(EastNorthUpFrame(coast.origin).matrix);
    scene.add(local);
    sky = AtmosphereExtension(
      id: 'sky',
      date: definition.epoch.add(const Duration(hours: 15)),
      appearance: AtmosphereAppearance(ground: false, haze: true),
    );
    scene.add(
      DirectionalLight(
        direction:
            CelestialDirections.at(
              definition.epoch.add(const Duration(hours: 15)),
            ).sunECEF *
            -1,
        color: const Color3(1, .94, .82),
        intensity: 3,
      ),
    );
    scene.add(
      HemisphereLight(
        up: EastNorthUpFrame(coast.origin).up,
        skyColor: const Color3(.56, .72, 1),
        groundColor: const Color3(.11, .15, .18),
        intensity: 1.4,
      ),
    );
    navigation = GlobeControlsPlugin(
      configureGlobe: (controls) => controls
        ..adjustHeight = false
        ..farMargin = 2,
    );
    _clockPlugin = _LabClock(this);
    ocean = OceanExtension(
      state: definition.sea,
      dependencies: {_clockPlugin.id, sky.atmosphere.id},
      createSampler: (context) => OceanSamplerCpu.create(
        state: definition.sea,
        frame: context.worldFrame,
        now: () => host.clock.instant,
        coverage: definition.hasCoast
            ? coast.coverage
            : const OceanAllWaterCoverage(),
      ),
      createPresentation: (context, sampler) async {
        // Publish before the first atmosphere frame, so culling cannot expose
        // an unfogged background for one frame while its inputs are replaced.
        if (this.fog != null) {
          await sky.atmosphere.controller.setAerialInputs(
            AerialPerspectiveInputs(fog: this.fog),
          );
        }
        final lease = await sky.atmosphere.controller.acquireLighting();
        try {
          final light = OceanLighting(
            atmosphere: lease.luts,
            sunDirectionEcef: CelestialDirections.at(
              sky.atmosphere.controller.date,
            ).sunECEF,
          );
          final root = context.sceneContext.createGpuScope(
            label: 'ocean-lab-effects',
          );
          final native = presentation = OceanNativePresentation(
            context: context,
            state: definition.sea,
            quality: detail.settings,
            hasUnderwater: definition.hasUnderwater,
            transitionDuration: const Duration(milliseconds: 350),
            retainedBytes: () =>
                _clockPlugin.payloadBytes +
                lease.luts.textures.values.fold(
                  0,
                  (n, t) => n + t.descriptor.byteLength,
                ),
            configureView: (frame) => OceanViewConfiguration(
              id: 'lab',
              camera: camera,
              size: PhysicalSize(frame.width, frame.height),
              displacementBoundMetres: definition.id == 'storm' ? 50 : 10,
              lighting: light,
              debug: debug,
              fog: this.fog,
              interactions: _clockPlugin.field,
              optics: OceanOptics(
                roughness: definition.id == 'storm' ? .11 : .045,
                absorptionPerMetre: definition.hasCoast
                    ? const Vec3(.18, .065, .045)
                    : const Vec3(.12, .035, .018),
              ),
              underwater: definition.hasUnderwater
                  ? OceanViewUnderwater(
                      mediumTransport: true,
                      sampleCamera: (camera, frame) async {
                        final instant = host.clock.instant.withTick(
                          (frame.seconds * host.clock.hz).round(),
                        );
                        final sample = (await sampler.sampleBatch([
                          OceanQuery(camera.position, instant),
                        ], OceanQueryPolicy())).single;
                        lastQuery = sample;
                        if (!sample.available) return null;
                        return OceanCameraWaterSample(
                          positionEcef: camera.position,
                          upEcef: sample.value!.normalEcef,
                          seconds: frame.seconds,
                          signedDistanceMetres:
                              (camera.position - sample.value!.positionEcef)
                                  .dot(sample.value!.normalEcef),
                        );
                      },
                    )
                  : null,
              caustics: definition.id == 'underwater'
                  ? [
                      OceanCausticRegion(
                        id: 'seabed',
                        patch: OceanPatchId(face: 0, level: 0, x: 0, y: 0),
                        extentMetres: 80,
                        depthMetres: 12,
                      ),
                    ]
                  : [],
            ),
          );
          return _LabPresentation(this, native, root, lease, light);
        } catch (_) {
          await lease.close();
          rethrow;
        }
      },
    );
    host = GeospatialPlugin(
      origin: coast.origin,
      clock: GeoSimulationClock(hz: 60, epoch: definition.epoch),
      extensions: [sky, ocean],
    );
    resetCamera();
  }
  List<ScenePlugin> get plugins => [
    ...host.scenePlugins,
    particles,
    navigation,
    _clockPlugin,
  ];
  void setRoute(bool value) {
    route = value;
    navigation.controls?.enabled = !value;
  }

  void resetCamera() {
    setRoute(false);
    camera.position = host.worldFrame.toEcef(definition.cameraLocal);
    camera.target = host.worldFrame.toEcef(definition.targetLocal);
    camera.up = host.worldFrame.vectorToEcef(const Vec3(0, 0, 1));
    camera.near = definition.id == 'orbit' ? 1000 : .1;
    presentation?.requestLodUpdate();
  }

  void selectDetail(OceanLabDetail value) {
    detail = value;
    presentation?.requestQuality(value.settings);
  }

  void setLayer(String id, bool visible) => host.layers.setVisible(id, visible);
}

final class _LabClock extends ScenePlugin {
  final OceanLabWorld lab;
  _LabClock(this.lab);
  @override
  String get id => 'ocean-lab.clock';
  @override
  Set<String> get dependencies => {
    GeospatialPlugin.pluginId,
    lab.particles.id,
    lab.navigation.id,
  };
  late GeoClockDriver driver;
  late GpuScope scope;
  late OceanInteractionField field;
  OceanSprayParticles? spray;
  PhysicsWorld? world;
  PhysicsBody? body;
  OceanPhysicsBridge? bridge;
  Group? vessel;
  Mesh? floor;
  int _sprayCapacity = -1;
  Vec3? _lodPosition, _lodTarget;
  int get payloadBytes =>
      field.logicalBytes + (spray?.logicalBytes ?? 0) + 128 * 128 * 32 + 1104;
  @override
  Future<void> attach(PluginContext context) async {
    driver =
        context.scope.keep(lab.host.clock.acquireDriver(id)) as GeoClockDriver;
    context.scope.keep(context.acquireFrameDemand());
    scope = context.createGpuScope(label: 'ocean-lab-interactions');
    field = await OceanInteractionField.create(
      scope,
      anchorEcef: lab.host.worldFrame.toEcef(Vec3.zero),
      initialTime: lab.host.clock.instant,
      settings: OceanInteractionSettings(resolution: 128, extentMetres: 160),
    );
    context.scope.onClose(() async {
      await bridge?.close();
      await spray?.close();
      await field.close();
      world?.close();
      lab.scene.remove(lab.local);
    });
    if (lab.definition.hasCoast) {
      lab.local.add(
        Mesh(
          oceanLabTerrain(
            await lab.coast.read('height'),
            origin: lab.coast.origin,
          ),
          StandardMaterial(color: const Color3(.57, .46, .27), roughness: .94),
        ),
      );
      for (var i = 0; i < (lab.definition.id == 'earth' ? 0 : 7); i++) {
        lab.local
            .add(
              Mesh(
                SphereGeometry(
                  radius: 1.5 + i * .18,
                  widthSegments: 16,
                  heightSegments: 10,
                ),
                StandardMaterial(
                  color: const Color3(.25, .28, .25),
                  roughness: .95,
                ),
              ),
            )
            .position = Vec3(
          38 + i * 3.0,
          -20 + i * 6.0,
          .8,
        );
      }
    } else if (lab.definition.id == 'underwater') {
      floor = lab.local.add(
        Mesh(
          PlaneGeometry(width: 160, height: 160),
          StandardMaterial(color: const Color3(.62, .57, .42), roughness: .95),
        ),
      )..position = const Vec3(0, 0, -12);
      for (var i = 0; i < 8; i++) {
        lab.local
            .add(
              Mesh(
                SphereGeometry(
                  radius: 1 + i * .15,
                  widthSegments: 16,
                  heightSegments: 10,
                ),
                StandardMaterial(
                  color: const Color3(.28, .32, .25),
                  roughness: .88,
                ),
              ),
            )
            .position = Vec3(
          -12 + i * 4.0,
          15 + math.sin(i) * 5,
          -11,
        );
      }
    }
    if (lab.definition.hasVessel) {
      world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81));
      body = world!.createBody(
        pose: PhysicsPose(position: const Vec3(0, 0, .2)),
      );
      body!.addCollider(const BoxShape(Vec3(1.5, 3.5, .75)), density: 430);
      vessel = lab.local.add(oceanLabVessel());
    }
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    lab.host.clock.paused = lab.paused;
    if (lab.simulationFailure != null) return;
    final quality = lab.presentation?.effectiveQuality ?? lab.detail.settings;
    if (lab.definition.hasVessel &&
        _sprayCapacity != quality.sprayParticleCap) {
      final candidate = await OceanSprayParticles.create(
        lab.particles.controller,
        name: 'lab.spray.${lab.host.clock.tick}.${quality.sprayParticleCap}',
        budget: quality.sprayParticleCap,
        autoAttach: false,
        initialTick: lab.host.clock.tick,
        generation: lab.host.clock.instant.generation,
        sourceWatermarks: spray?.sourceWatermarks ?? const {},
        hz: 60,
        particlesPerEvent: 8,
        gravity: lab.host.worldFrame.vectorToEcef(const Vec3(0, 0, -9.81)),
        anchor: field.anchorEcef,
        maxLogicalBytes: quality.gpuBudgetBytes,
        retainedBytes:
            (lab.presentation?.controller?.estimatedBytes ?? 0) + payloadBytes,
      );
      for (final object in candidate.objects) {
        lab.scene.add(object);
      }
      final previous = spray;
      spray = candidate;
      _sprayCapacity = quality.sprayParticleCap;
      await previous?.close();
    }
    if (world != null && bridge == null) {
      bridge = OceanPhysicsBridge(
        world: world!,
        sampler: lab.host.registry.find(oceanSampler)!,
        policy: OceanQueryPolicy(),
      );
      bridge!.bind(
        body!,
        oceanLabHull(),
        solver: BuoyancySolver(drag: BuoyancyDrag(linear: 2500, angular: 4000)),
      );
    }
    final due = driver.admit(frame.delta);
    try {
      for (var i = 0; i < due; i++) {
        driver.step();
        final instant = lab.host.clock.instant;
        final events = <OceanSprayEvent>[];
        if (bridge case final physics?) {
          final forces = await physics.prepare(instant);
          physics.apply(forces, world!.fixedStep);
          world!.step();
          final state = body!.state;
          vessel!
            ..position = state.pose.position
            ..quaternion = state.pose.rotation;
          if (instant.tick % 6 == 0) {
            final position = lab.host.worldFrame.toEcef(
              state.pose.position + const Vec3(0, -3.4, -.1),
            );
            final velocity = lab.host.worldFrame.vectorToEcef(state.velocity);
            final energy = (state.velocity.length * .02).clamp(0.0, .2);
            if (energy > .0001) {
              final admission = lab.lastWakeAdmission = field.enqueue(
                OceanInteraction(
                  id: OceanInteractionId('hull', instant.tick),
                  time: instant,
                  ecefPosition: position,
                  relativeVelocity: velocity,
                  radiusMetres: math.max(1.4, field.settings.cellMetres * 2),
                  energy: energy,
                ),
              );
              if (admission == OceanInteractionAdmission.accepted) {
                events.add(
                  OceanSprayEvent(
                    source: 'hull',
                    sequence: instant.tick,
                    tick: instant.tick,
                    generation: instant.generation,
                    position: position,
                    velocity: velocity,
                    surfaceNormal: field.up,
                    energy: energy,
                  ),
                );
              }
            }
          }
        }
        await field.step(instant);
        await spray?.advance(instant.tick, events: events);
      }
    } catch (error) {
      lab.simulationFailure = error;
      lab.paused = true;
      rethrow;
    }
    if (frame.number % 15 == 0 &&
        (_lodPosition == null ||
            lab.camera.position.distanceTo(_lodPosition!) > .1 ||
            lab.camera.target.distanceTo(_lodTarget!) > .1)) {
      lab.presentation?.requestLodUpdate();
      _lodPosition = lab.camera.position;
      _lodTarget = lab.camera.target;
    }
    if (lab.route && lab.definition.id == 'orbit') {
      final t = (lab.host.clock.instant.seconds / 30).clamp(0.0, 1.0);
      final altitude = math.exp(math.log(18000000) * (1 - t) + math.log(8) * t);
      lab.camera.position = lab.host.worldFrame.toEcef(
        Vec3(0, -altitude * .05 - 20, altitude),
      );
      lab.camera.target = lab.host.worldFrame.toEcef(
        Vec3(0, 40 * t, -6378137 * (1 - t)),
      );
      lab.camera.near = math.max(.1, altitude / 10000);
    }
  }
}

final class _LabPresentation implements OceanPresentation {
  final OceanLabWorld lab;
  final OceanNativePresentation native;
  final GpuScope scope;
  final AtmosphereLutLease lease;
  final OceanLighting light;
  GpuScope? effects;
  OceanFoamProducer? foam;
  OceanViewResources? published;
  Object? medium;
  Mesh? receiver;
  _LabPresentation(this.lab, this.native, this.scope, this.lease, this.light);
  @override
  bool get hasUnderwater => native.hasUnderwater;
  @override
  bool get isReady => native.isReady;
  @override
  Future<void> prepare(
    GeoInstant instant,
    FrameInfo frame,
    OceanLayerVisibility visibility,
  ) async {
    await native.prepare(instant, frame, visibility);
    final view = native.view!;
    final nextMedium = visibility.underwater
        ? view.underwater?.aerialMedium
        : null;
    if (!identical(nextMedium, medium)) {
      await lab.sky.atmosphere.controller.setAerialInputs(
        AerialPerspectiveInputs(medium: nextMedium, fog: lab.fog),
      );
      medium = nextMedium;
    }
    if (!identical(published, view)) {
      final candidate = scope.createChild(label: 'ocean-lab-frame-effects');
      Mesh? nextReceiver;
      try {
        final anchor = lab._clockPlugin.field.anchorEcef;
        final face = oceanCubeFaces.reduce(
          (a, b) => a.normal.dot(anchor) >= b.normal.dot(anchor) ? a : b,
        );
        final water = await OceanWaterMaterial.create(
          candidate,
          waves: native.controller!.waves,
          patch: OceanPatchId(
            face: oceanCubeFaces.indexOf(face),
            level: 0,
            x: 0,
            y: 0,
          ),
          originEcef: lab._clockPlugin.field.anchorEcef,
          geometrySpacingMetres: 1,
          lighting: light,
        );
        final nextFoam = await OceanFoamProducer.create(
          candidate,
          water: water,
          field: lab._clockPlugin.field,
          depth: lab.definition.hasCoast
              ? OceanFoamDepthMap(
                  sourceId: lab.coast.sourceId,
                  revision: lab.coast.dataRevision,
                  meanLevelMetres: lab.definition.meanLevel,
                  grid: await _foamDepth(),
                )
              : null,
        );
        final caustics = view.caustics['seabed'];
        if (caustics != null && lab._clockPlugin.floor != null) {
          // The receiver geometry uses local ENU. Its shader needs ECEF offsets.
          // Use a separate ECEF-oriented floor for the caustic material below.
          final floor = lab._clockPlugin.floor!;
          final origin = lab.host.worldFrame.toEcef(const Vec3(0, 0, -12));
          final points = floor.geometry.positions;
          final positions = <double>[], normals = <double>[];
          for (var i = 0; i < points.length; i += 3) {
            positions.addAll(
              lab.host.worldFrame
                  .vectorToEcef(Vec3(points[i], points[i + 1], points[i + 2]))
                  .storage,
            );
            normals.addAll(
              lab.host.worldFrame.vectorToEcef(const Vec3(0, 0, 1)).storage,
            );
          }
          final material = await caustics.createReceiverMaterial(
            candidate,
            geometryOriginEcef: origin,
            albedo: const Color3(.62, .57, .42),
            ambientRadiance: const Vec3(.12, .15, .17),
          );
          nextReceiver = Mesh(
            BufferGeometry(
              positions: positions,
              normals: normals,
              indices: floor.geometry.indices,
            ),
            material,
          )..position = origin;
        }
        lab._clockPlugin.floor?.visible = nextReceiver == null;
        if (receiver != null) lab.scene.remove(receiver!);
        receiver = nextReceiver;
        if (nextReceiver != null) lab.scene.add(nextReceiver);
        final previous = effects;
        effects = candidate;
        foam = nextFoam;
        published = view;
        await previous?.close();
      } catch (_) {
        if (!identical(effects, candidate)) await candidate.close();
        rethrow;
      }
    }
    await foam!.update();
  }

  Future<GeoScalarGrid> _foamDepth() async {
    if (lab.definition.id != 'earth') return lab.coast.read('depth');
    final height = await lab.coast.read('height');
    return GeoScalarGrid(
      width: height.width,
      height: height.height,
      bounds: height.bounds,
      values: Float64List.fromList([
        for (final elevation in height.values)
          math.max(0, lab.definition.meanLevel - elevation),
      ]),
    );
  }

  @override
  Future<void> close() async {
    if (receiver != null) lab.scene.remove(receiver!);
    Object? failure;
    StackTrace? trace;
    for (final close in [
      if (effects != null) effects!.close,
      scope.close,
      native.close,
      lease.close,
    ]) {
      try {
        await close();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}
