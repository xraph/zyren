# zyren_particles

Native GPU particles and ribbons for Zyren. You can attach emitters to ordinary
scene objects, animate them with a fixed simulation step, and control playback
through the plugin service. The optional package depends only on `zyren` at
runtime. Flutter and geospatial packages are not required.

## Run the example

Use the workspace Flutter version in `.fvmrc`:

```sh
flutter pub get
cd examples/particles
flutter run -d macos
```

[Particle Lab](../../examples/particles) includes sparks, animated sprites,
ribbons, flow fields and mesh particles. Its controls wrap on narrow screens.
You can pause, drain, reset, emit a burst or explicitly inspect the live count.

## Attach an emitter

```dart
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_particles/zyren_particles.dart';

final viewport = SceneController(
  scene: Scene(),
  camera: PerspectiveCamera(position: const Vec3(0, 1, 5)),
);
final particles = viewport.use(ParticlePlugin(emitters: [
  ParticleEmitter(
    name: 'sparks',
    settings: ParticleSettings(
      capacity: 4096,
      rate: 300,
      lifetime: 2,
      seed: 42,
      shape: ConeParticleShape(radius: .1, height: .2),
      velocity: const Vec3(0, 3, 0),
      velocitySpread: const Vec3(1, 1, 1),
      appearance: ParticleAppearance.stretched,
      blend: ParticleBlend.additive,
      trails: TrailSettings(samples: 16, width: .4),
    ),
  ),
]));

// Build SceneView(controller: viewport), then await viewport.ready.
// After attachment:
await particles.controller.pause('sparks');
await particles.controller.resume('sparks');
await particles.controller.burst('sparks', 100);
await particles.controller.stop('sparks'); // Existing particles drain.
await particles.controller.stop('sparks', clear: true);
```

You can use the same plugin with `SceneEngine.create` in a Dart application.
Other plugins can retrieve `context.service(particleSystems)`. Each scene needs
its own plugin instance. Dispose the viewport or engine to release its emitters.

## Emission and appearance

| API | Behavior |
| --- | --- |
| `PointParticleShape`, `BoxParticleShape` | Fixed point or uniform box volume |
| `SphereParticleShape` | Uniform volume or surface |
| `ConeParticleShape` | Uniform cone volume along local positive Y |
| `SurfaceParticleShape` | Area-weighted sampling of triangle geometry |
| `ParticleBurst` | Scheduled emission, repeated when duration loops |
| `ParticleCurve`, `ParticleGradient` | Piecewise linear size, rotation and RGBA over normalized lifetime |
| `ParticleTexture` | Copied RGBA pixels, atlas rows/columns and frame rate |
| `ConstantParticleForce`, `FlowParticleForce`, `NoiseParticleForce` | Acceleration, smooth periodic flow or seeded lattice noise |
| `ParticlePlane`, `ParticleBox.planes` | Position projection and velocity reflection with restitution |
| `ParticleAppearance` | Camera-facing billboard, emitter-oriented quad, velocity stretch or mesh |
| `ParticleBlend` | Per-emitter sorted alpha, additive or opaque |
| `TrailSettings` | Camera-facing ribbon from bounded position history |

Mesh particles use unlit color and optional UV0 texture data. Geometry is copied
into a bounded carrier mesh; particles move in the vertex shader. Ribbons use a
second draw. The public mesh shader API does not expose indirect draws, so this
implementation does not claim indirect instancing or per-particle mesh lighting.

The default GPU path keeps simulation, alpha sorting and history on the device.
There is no routine particle readback. `ParticlePath.reference` runs the same
fixed-step equations in Dart and uploads packed buffers to the native renderer;
it is useful when compute is unavailable or when you need a reference result.
Select it explicitly. Unsupported capabilities and shader compilation failures
are reported to you rather than changing the selected path silently.

## Spaces, playback and configuration

In `ParticleSpace.local`, particles follow the emitter hierarchy. In
`ParticleSpace.world`, particles keep their birth rotation and scale when that
hierarchy moves. World positions use a fixed nearby storage origin until reset.
Collision planes retain their world coordinates across that rebase. Forces
receive local coordinates in local mode and world coordinates in world mode;
spatial force calculations still have GPU float precision, so choose local mode
for fine noise fields at very large coordinates.

Camera orientation comes from Zyren's camera target and up vector. If you drive
`ParticleRenderer` directly, pass `particleCameraTransform(camera)` to `update`,
and attach its `mesh` and optional `ribbon` under your emitter object. Supply
consecutive ticks from `ParticleClock`; await each operation before the next.
Closing the renderer drains accepted work and releases its child GPU scope.

`pause` freezes both emission and integration. `resume` restores playing or
draining. `stop` drains; `reset` clears particles and returns to stopped. A burst
on a stopped controller runs and drains that burst, while a burst queued during
pause waits for resume. Starting a stopped emitter restarts its seed.

You can `add`, `remove` or `configure` a named emitter through the controller.
Configuration builds and prewarms a replacement before swapping it in. A failed
replacement preserves the current emitter. Successful configuration restarts
the seed and preserves the playback category. Reattachment and `restore` rebuild
resources from settings; lost GPU particle state is not recovered. Use the
viewport's recovery policy to recreate the native backend after device loss.

`inspect` and `inspectBounds` perform explicit readbacks on the GPU path. Bounds
include particle sizes, retained birth scale and ribbon samples. Keep inspection
out of the render loop. `measurements` reports submitted dispatches, uploaded
bytes and host duration; GPU duration and a GPU live count are unknown until
measured, and are not inferred from capacity.

## Limits and rendering rules

- An emitter holds 1 to 65,536 particles; a plugin holds up to 32 emitters.
  Mesh and ribbon expansion is also bounded by native geometry limits.
- Every emission event reserves `serial % capacity`. `dropNew` keeps a live slot
  and drops that event. `replaceOldest` replaces the ring slot. There is no
  global free-slot search. Oversized bursts retain the first or last event for
  each slot according to that policy.
- The default fixed step is 1/120 second. A clock advances at most 32 ticks per
  call and retains backlog; you can raise this to 4,096 for offline work. The
  scene engine supplies its own clamped frame delta. Pausing the app does not
  promise a wall-clock replay of the suspended interval.
- Reset before 16,777,215 ticks or attempted emissions. The clock and renderer
  reject exhausted counters to preserve exact GPU identities. Prewarm is capped
  at 30 seconds, lifetime at one hour, and queued manual bursts at capacity.
- Alpha order is sorted within each emitter, including camera-only updates.
  Separate emitters and ribbons use the scene's ordinary mesh ordering. This
  does not implement global order-independent transparency.
- Depth test/write and scene clipping are supported. Soft depth intersections
  throw `UnsupportedError`: native mesh materials have no sampled scene-depth
  input. Disable `softIntersections` until that shared API is available.
- Custom `ParticleShape` and `ParticleForce` implementations must provide pure,
  finite CPU and WGSL behavior. Keep them immutable while attached. A CPU
  callback cannot be translated into a GPU program automatically.

## Verify

Run from the package directory so Dart builds the current native assets:

```sh
cd packages/zyren_particles
dart analyze lib test
dart test --concurrency=1
RUN_NATIVE_GPU=1 dart test --concurrency=1 --timeout=3m
```

The first test command covers CPU contracts and explicitly skips native tests.
The second requires Metal, Vulkan or DX12 hardware. You can set
`ZYREN_PARTICLE_EVIDENCE` to an absolute output directory to save image bytes and
measurements. [Qualification](qualification/2026-10-02.md) records actual devices,
checks and gaps. [Completion status](COMPLETION.md) separates implementation from
platform verification. The package is not published to pub.dev.
