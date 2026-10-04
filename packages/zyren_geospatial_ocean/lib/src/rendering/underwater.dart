import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'lighting.dart';
import 'optics.dart';
import 'surface_capture.dart';
import 'underwater_wgsl.dart';
import 'water_volume.dart';

/// Effective work limits. Zero shaft steps removes direct single scattering;
/// zero caustic resolution or particle budget disables that contribution.
final class OceanUnderwaterSettings {
  final Vec3? absorptionPerMetre, scatteringPerMetre;
  final int shaftSteps, causticResolution, particleBudget;
  final double maximumIntegrationMetres;
  OceanUnderwaterSettings({
    this.absorptionPerMetre,
    this.scatteringPerMetre,
    this.shaftSteps = 16,
    this.causticResolution = 128,
    this.particleBudget = 0,
    this.maximumIntegrationMetres = 250,
  }) {
    for (final coefficient in [absorptionPerMetre, scatteringPerMetre]) {
      if (coefficient != null) {
        validateOceanRadiance(coefficient, 'Underwater coefficient');
      }
    }
    if (shaftSteps < 0 ||
        shaftSteps > 64 ||
        causticResolution < 0 ||
        causticResolution > 1024 ||
        (causticResolution != 0 &&
            (causticResolution < 16 ||
                causticResolution & (causticResolution - 1) != 0)) ||
        particleBudget < 0 ||
        particleBudget > 65536 ||
        !maximumIntegrationMetres.isFinite ||
        maximumIntegrationMetres <= 0 ||
        maximumIntegrationMetres > 60000) {
      throw ArgumentError('Invalid underwater work limits.');
    }
  }
  OceanOptics resolve(OceanOptics source) => OceanOptics(
    absorptionPerMetre: absorptionPerMetre ?? source.absorptionPerMetre,
    scatteringPerMetre: scatteringPerMetre ?? source.scatteringPerMetre,
    indexOfRefraction: source.indexOfRefraction,
    roughness: source.roughness,
    maximumPathMetres: maximumIntegrationMetres,
  );
}

/// Optional projected sunlight visibility. UV comes from dot(world - anchor,
/// axis) + .5. Outside the map, visibility is zero. Values are linear [0,1].
/// This is an explicit caller-provided shadow input, not a renderer shadow map.
final class OceanSunVisibility {
  final GpuResource<Texture> texture;
  final Vec3 anchor, uPerMetre, vPerMetre;
  OceanSunVisibility({
    required this.texture,
    required this.anchor,
    required this.uPerMetre,
    required this.vPerMetre,
  }) {
    final descriptor = texture.descriptor as TextureDescriptor;
    if (!anchor.isFinite ||
        !uPerMetre.isFinite ||
        !vPerMetre.isFinite ||
        uPerMetre.cross(vPerMetre).length2 < 1e-24 ||
        descriptor.dimension != TextureDimension.d2 ||
        !descriptor.usage.contains(TextureUsage.sampled) ||
        descriptor.format == TextureFormat.rgba8UnormSrgb) {
      throw ArgumentError(
        'Sun visibility needs a linear 2D map and independent projection axes.',
      );
    }
  }
}

/// One scoped HDR volume effect. Prepare it after the water surface capture and
/// before the scene submission. The capture must include every visible water
/// patch. A physical or visual surface query supplies the camera's signed distance
/// only for rays with no surface hit; failed queries must not be passed as zero.
final class OceanUnderwaterPass {
  static final _owners = Expando<OceanUnderwaterPass>('ocean-underwater-owner');
  final GpuScope _scope;
  final GpuResource<Buffer> _uniform;
  final OceanSurfaceCapture surface;
  final OceanWaterVolume volume;
  final OceanOptics optics;
  final OceanUnderwaterSettings settings;
  final OceanLighting lighting;
  final Mat4 worldToEcef;
  final OceanSunVisibility? sunVisibility;
  final ScreenEffect effect;
  final AerialMediumInputs? aerialMedium;
  final PhysicalSize? transportSize;
  final OceanSubmersion submersion = OceanSubmersion();
  EffectRegistration? _registration;
  Scene? _scene;
  Future<void> _queue = Future.value();
  bool _closed = false;
  bool get isClosed => _closed || _scope.isClosed;
  bool get hasShadowVisibility => sunVisibility != null;
  int get logicalBytes =>
      448 +
      (sunVisibility == null ? 16 : 0) +
      (transportSize == null
          ? 0
          : transportSize!.width * transportSize!.height * 16);
  OceanUnderwaterPass._(
    this._scope,
    this._uniform,
    this.surface,
    this.volume,
    this.optics,
    this.settings,
    this.lighting,
    this.worldToEcef,
    this.sunVisibility,
    this.effect,
    this.aerialMedium,
    this.transportSize,
  );

  static Future<OceanUnderwaterPass> create(
    GpuScope parent, {
    required OceanSurfaceCapture surface,
    OceanWaterVolume? volume,
    OceanOptics? optics,
    OceanUnderwaterSettings? settings,
    OceanLighting? lighting,
    Mat4? worldToEcef,
    OceanSunVisibility? sunVisibility,
    // With a transport size, this pass writes a medium map for atmosphere and
    // leaves scene color unchanged. Install aerialMedium on AerialPerspectiveInputs.
    PhysicalSize? transportSize,
    int maxTransportPixels = 2073600,
  }) async {
    if (surface.isClosed) throw StateError('Surface capture closed.');
    if (transportSize != null &&
        (transportSize.width < 1 ||
            transportSize.height < 1 ||
            transportSize.width * transportSize.height > maxTransportPixels ||
            maxTransportPixels < 1 ||
            maxTransportPixels > 4194304)) {
      throw ArgumentError('Medium transport exceeds its pixel budget.');
    }
    final config = settings ?? OceanUnderwaterSettings();
    final optical = config.resolve(optics ?? OceanOptics());
    final light = lighting ?? OceanLighting();
    final transform = worldToEcef ?? Mat4.identity();
    final m = transform.storage;
    final axes = [
      for (var i = 0; i < 3; i++) Vec3(m[i * 4], m[i * 4 + 1], m[i * 4 + 2]),
    ];
    if ([m[3], m[7], m[11], m[15] - 1].any((v) => v.abs() > 1e-12) ||
        axes.any((v) => (v.length - 1).abs() > 1e-8) ||
        axes[0].cross(axes[1]).distanceTo(axes[2]) > 1e-8) {
      throw ArgumentError(
        'Underwater worldToEcef must be a proper rigid transform.',
      );
    }
    final bounds = volume ?? OceanWaterVolume();
    final scope = parent.createChild(label: 'ocean-underwater');
    try {
      final uniform = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 448,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final shadow = sunVisibility == null
          ? await scope.resources.createTexture(
              TextureDescriptor(
                width: 1,
                height: 1,
                format: TextureFormat.rgba32Float,
                usage: {TextureUsage.sampled},
              ),
            )
          : await scope.resources.retain(sunVisibility.texture);
      final transport = transportSize == null
          ? null
          : await scope.resources.createTexture(
              TextureDescriptor(
                width: transportSize.width * 2,
                height: transportSize.height,
                format: TextureFormat.rgba16Float,
                usage: {TextureUsage.sampled, TextureUsage.storage},
              ),
            );
      final lightLibrary = await OceanMediumLighting.create(scope, light);
      final bindings = ShaderBindings([
        ...lightLibrary.bindings,
        BufferBinding.uniform(0, uniform, group: 1),
        TextureBinding.sampled(
          1,
          await scope.resources.retain(surface.texture),
          group: 1,
        ),
        TextureBinding.sampled(2, shadow, group: 1),
        if (transport != null) TextureBinding.storage(3, transport, group: 1),
      ]);
      final program = await scope.shaders.compile(
        ShaderSource.wgsl(
          '${PostProcessDescriptor.interfaceWgsl}\n${lightLibrary.wgsl}\n${oceanUnderwaterWgsl(transport: transport != null)}',
          label: 'ocean-underwater',
        ),
      );
      final effect = await scope.materials.compileEffect(
        PostProcessDescriptor(
          program: program,
          bindings: bindings,
          label: 'ocean underwater',
        ),
      );
      return OceanUnderwaterPass._(
        scope,
        uniform,
        surface,
        bounds,
        optical,
        config,
        light,
        transform,
        sunVisibility,
        effect,
        transport == null ? null : AerialMediumInputs(transport: transport),
        transportSize,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  /// Replaces the previous ocean volume in the same slot only after this effect
  /// has compiled and its first frame has been prepared. A failed candidate
  /// leaves the old registration intact. Closing the old pass cannot remove us.
  void attach(Scene scene) {
    if (isClosed || !_prepared) {
      throw StateError('Prepare underwater before attaching it.');
    }
    if (_scene != null && !identical(_scene, scene)) {
      throw StateError('An underwater pass belongs to one scene.');
    }
    final previous = _owners[scene];
    if (identical(previous, this)) return;
    final registration = previous?._registration;
    if (registration != null && !registration.isDisposed) {
      registration.replace(effect);
      previous!._registration = null;
      previous._scene = null;
      _registration = registration;
    } else {
      _registration = scene.addEffect(effect, order: -100);
    }
    _owners[scene] = this;
    _scene = scene;
  }

  /// Removes the visual pass without retiring its resources or changing queries.
  void detach() {
    _registration?.dispose();
    _registration = null;
    if (_scene case final scene? when identical(_owners[scene], this)) {
      _owners[scene] = null;
    }
    _scene = null;
  }

  bool _prepared = false;
  Future<void> prepare({
    required Camera camera,
    required PhysicalSize viewport,
    required double signedSurfaceDistance,
    required Vec3 surfaceUp,
    double sunVisibilityFallback = 1,
  }) {
    final next = _queue.then((_) async {
      if (isClosed) throw StateError('Underwater pass closed.');
      surface.checkCurrent(camera, viewport);
      if (transportSize != null &&
          (transportSize!.width != viewport.width ||
              transportSize!.height != viewport.height)) {
        throw StateError('Medium transport must match the current viewport.');
      }
      if (!signedSurfaceDistance.isFinite ||
          !surfaceUp.isFinite ||
          (surfaceUp.length - 1).abs() > 1e-8 ||
          !sunVisibilityFallback.isFinite ||
          sunVisibilityFallback < 0 ||
          sunVisibilityFallback > 1) {
        throw ArgumentError(
          'Underwater frames need a finite surface distance, unit up and valid visibility.',
        );
      }
      final data = Float32List(112);
      void vector(int slot, Vec3 value, [double w = 0]) =>
          data.setRange(slot * 4, slot * 4 + 4, [value.x, value.y, value.z, w]);
      final forward = (camera.target - camera.position).normalized();
      vector(
        0,
        camera.position - volume.anchor,
        volume.planes.length.toDouble(),
      );
      vector(1, forward, camera is OrthographicCamera ? camera.near : -1);
      vector(2, optics.absorptionPerMetre, settings.maximumIntegrationMetres);
      vector(3, optics.scatteringPerMetre, signedSurfaceDistance < 0 ? 1 : 0);
      vector(4, lighting.skyRadiance, settings.shaftSteps.toDouble());
      final m = worldToEcef.storage;
      final x = Vec3(m[0], m[1], m[2]),
          y = Vec3(m[4], m[5], m[6]),
          z = Vec3(m[8], m[9], m[10]);
      final sun = lighting.sunDirectionEcef.normalized();
      vector(
        5,
        Vec3(sun.dot(x), sun.dot(y), sun.dot(z)),
        sunVisibilityFallback,
      );
      vector(17, sun);
      vector(18, x * surfaceUp.x + y * surfaceUp.y + z * surfaceUp.z);
      data[76] = lighting.environment?.intensity ?? 1;
      data[77] = lighting.environment?.rotation ?? 0;
      vector(6, lighting.sunIrradiance, optics.indexOfRefraction);
      vector(7, surfaceUp, signedSurfaceDistance);
      final shadow = sunVisibility;
      vector(
        8,
        shadow == null ? Vec3.zero : camera.position - shadow.anchor,
        shadow == null ? 0 : 1,
      );
      vector(9, shadow?.uPerMetre ?? Vec3.zero);
      vector(10, shadow?.vPerMetre ?? Vec3.zero);
      for (var i = 0; i < volume.planes.length; i++) {
        vector(11 + i, volume.planes[i].normal, volume.planes[i].offset);
      }
      if (data.any((v) => !v.isFinite)) {
        throw ArgumentError('Underwater frame exceeds native float range.');
      }
      await _scope.resources.writeBuffer(_uniform, data);
      surface.checkCurrent(camera, viewport);
      submersion.update(signedSurfaceDistance);
      _prepared = true;
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    detach();
    await _queue;
    await _scope.close();
  }
}
