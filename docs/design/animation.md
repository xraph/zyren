# Animation clips and playback

You can animate local transforms from Dart and attach the same mixer to a Flutter
view for automatic playback:

```dart
final clip = AnimationClip(
  name: 'Slide',
  tracks: [
    VectorKeyframeTrack.position(
      target: 'slide',
      times: [0, 1, 2],
      values: [Vec3.zero, const Vec3(2, 0, 0), Vec3.zero],
    ),
  ],
);
final mixer = controller.use(AnimationMixer(nodes: {'slide': mesh}));
final action = mixer.play(clip);

action.pause();
action.seek(const Duration(milliseconds: 500));
action.speed = -1;
action.resume();
```

Import `gpu3d/gpu3d.dart` in Dart or `flutter_gpu3d/flutter_gpu3d.dart` in Flutter.
Register the mixer before the view initializes, like other scene plugins.
Each mixer gets a unique plugin ID; supply `id` when another plugin needs a
stable dependency on it. The returned type is `AnimationAction`, avoiding a
name collision with Flutter's `Action` class.

Without Flutter, construct the mixer and call `mixer.update(delta)` with a
nonnegative elapsed step. Explicit steps advance immediately. An attached mixer
advances from the engine's frame delta; do not also advance it manually unless
you intend to apply both steps.

## Models loaded after view initialization

Register an `AnimationSystem` before attaching the view, then add each loaded
model's mixer:

```dart
final playback = controller.use(AnimationSystem());
// Later, after loading and instantiating a model:
final registration = playback.add(instance.mixer);
final action = instance.mixer.play(instance.animations.first);
registration.dispose(); // Stops automatic updates, preserving action state.
```

A mixer belongs to one system or direct plugin attachment. Duplicate ownership
is rejected. Keep the registration alongside the model and dispose it when you
replace or remove that model. Detaching a system releases all frame demand while
retaining its mixer registrations for reattachment. Each newly attached mixer
skips its first frame delta. Systems support up to 4096 registered mixers.

The optional `gpu3d_gltf` loader publishes these same core clips and mixers.
See its [instance and scene selection API](../../packages/gpu3d_gltf/README.md#animation).

## Tracks and instance ownership

Track targets are your stable string IDs. The `nodes` map resolves them to
objects for this instance, so you can reuse a clip with another map without
sharing mutable playback or transforms. Object names are display labels and do
not participate in binding. Duplicate node aliases within one map and duplicate
target/property channels within one clip are rejected.

`VectorKeyframeTrack.position`, `VectorKeyframeTrack.scale` and
`QuaternionKeyframeTrack` are typed transform channels. Times are double-precision
seconds, strictly increasing and nonnegative. The track copies its lists, and
its values are immutable. Sampling before the first or after the last key keeps
the nearest endpoint. Channels may begin and end at different times.

The interpolation rules follow [glTF Appendix C](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#appendix-c-interpolation):

- `step` keeps the preceding key, changing exactly at the next timestamp.
- `linear` interpolates vectors and uses shortest-path spherical interpolation
  for rotations.
- `cubicSpline` uses Hermite interpolation with per-key `inTangents` and
  `outTangents`, expressed as rates per second. Segment duration scales the
  tangents. Rotations interpolate components with their authored signs and then
  normalize, so quaternion tangents must not be normalized or flipped.

Cubic tracks need at least two keys. A zero-length interpolated quaternion is an
error. Vector values and tangents must be finite; scale keys and sampled scales
must also be nonsingular. A mirrored scale is valid, but a continuous transition
through zero scale is not renderable by this transform profile.

A clip's duration defaults to its last key. You can pass `durationSeconds` to
hold the final keys longer. The `duration` getter provides the nearest
microsecond for controls; internal sampling retains double-precision seconds.
A zero-duration clip applies its pose and finishes without continuous demand.

## Actions, mixing and frame demand

Each `play` call creates an independent action. Its options are `loop` (`repeat`
by default), `speed` (`1`) and `weight` (`1`). `actions` lists every unstopped
action, including paused and finished ones.

| Control | Behaviour |
| --- | --- |
| `pause()` | Holds this action's pose and stops its clock |
| `resume()` | Continues a paused action; restarts a finished action from the appropriate end |
| `seek(Duration)` | Applies a nonnegative position immediately, clamped at clip end; preserves pause and leaves a previously finished action paused |
| `speed` | Finite `[-1024, 1024]`; negative plays backwards and zero stops clock demand |
| `weight` | Finite `[0, 1]`; zero-weight running actions still advance their clocks |
| `loop` | `once`, `repeat` or `pingPong`; changing it preserves local time and resets the ping-pong phase |
| `stop()` | Removes this action and restores channels no other action owns |
| `stopAll()` | Removes all mixer actions and restores their rest values |

A newly played negative-speed action starts at the end. Repeat wraps exact end
boundaries to zero; ping-pong reflects at each endpoint. Once playback retains
its final contribution when it finishes. Call `stop` to release it. Stopped
actions cannot be resumed; play the clip again.

Mixing happens per node and property. Below a total weight of one, the remainder
comes from the rest value captured when the first action claimed that channel.
Above one, contributions are normalized. Vector contributions use weighted
linear interpolation. Rotations accumulate spherical blends in play order, then
blend any remaining rest weight. Give each node/property one owning mixer.

The mixer validates the complete sampled pose before publishing built-in
transforms or advancing playheads. A singular scale or invalid rotation leaves
the prior pose and action times intact. Stopping the last owner releases its
rest snapshot, so later playback captures subsequent application edits.

The plugin holds one frame demand while any action advances. Paused, finished
and zero-speed actions release it. Starting or resuming an action skips its first
automatic delta, preventing time spent idle from becoming a jump. Other running
actions continue normally. Detaching releases demand and preserves playback
state for explicit Dart updates or a later attachment.

## Bounds and verification

A track supports up to one million keys; a clip supports 4096 channels and one
million total keys. Constructors check array length before copying oversized
input. A mixer supports 32768 distinct nodes, 256 unstopped actions and 32768
active track bindings. Key times and clip duration are bounded to 1e9 seconds.
These are admission bounds, not a frame-time guarantee.

The core tests cover interpolation, duplicate targets, malformed inputs, reverse
and loop boundaries, weighted rest poses, instance isolation and atomic failures.
Plugin tests cover demand release and idle-time handling. Native pixels verify
that animated transforms preserve captured frames and avoid geometry reuploads.
The Flutter integration plays and seeks two copies of one clip, then verifies
that presentation stops after both pause.

Run the demo from `examples/shader_lab`:

```sh
flutter run -d macos -t lib/animation.dart
flutter run --release -d DEVICE_ID -t lib/animation.dart
flutter test integration_test/animation_test.dart -d DEVICE_ID
```

The two scene hierarchies share a clip and immutable geometry. This is transform
animation. Native GPU instancing, skinning and morph deformation use the
[deformation API](deformation.md). glTF transform and morph-weight import use
these same tracks. Track completion events, additive blending and
finite repetition counts also remain open parts of the broader animation API.
