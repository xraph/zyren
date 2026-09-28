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
by default), `speed` (`1`), `weight` (`1`) and optional `repetitions`. `actions` lists every unstopped
action, including paused and finished ones.

| Control | Behaviour |
| --- | --- |
| `pause()` | Holds this action's pose and stops its clock |
| `resume()` | Continues a paused action; restarts a finished action from the appropriate end |
| `seek(Duration)` | Applies a nonnegative position immediately, clamped at clip end; preserves pause and leaves a previously finished action paused |
| `speed` | Finite `[-1024, 1024]`; negative plays backwards and zero stops clock demand; assigning cancels a speed transition |
| `weight` | Finite `[0, 1]`; zero-weight running actions still advance their clocks; assigning cancels a fade |
| `loop` | `once`, `repeat` or `pingPong`; changing it preserves local time and resets phase and repeat count |
| `repetitions` | Total traversals, including the first; null is unlimited; changing it resets the completed count |
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

The plugin holds one frame demand while any playhead or transition advances.
Paused, finished and zero-speed actions release it once their transitions finish.
Starting or resuming an action skips its first
automatic delta, preventing time spent idle from becoming a jump. Other running
actions continue normally. Detaching releases demand and preserves playback
state for explicit Dart updates or a later attachment.

## Additive layers

You can layer an ordinary clip over the normal animation without copying or
rewriting its keys:

```dart
final lean = mixer.play(
  leanClip,
  blendMode: AnimationBlendMode.additive,
  referenceTime: const Duration(milliseconds: 500),
  weight: .35,
);
lean.weight = .8;
lean.pause(); // Holds the layer's contribution without advancing its clock.
lean.stop();  // Removes this layer while the other actions keep playing.
```

At the reference time the layer contributes no offset. The default reference is
zero. An explicit reference must lie inside the clip and produce a valid pose;
normal playback only accepts the default reference. The action captures that
reference once. `blendMode` and `referenceTime` are fixed for the action, while
its weight, clock and loop controls work as before. A new action starts at the
usual playback endpoint, so a reference in the middle can contribute an offset
immediately.

Position, scale and morph weights use `sample - reference`. Scale is a numeric
difference, not a scale ratio. Rotation uses `inverse(reference) * sample` and
blends that offset from the identity quaternion. The weighted rotation is
composed in local space after the normal pose; multiple rotation layers compose
in play order, which matters for rotations around different axes.

The mixer completes normal weighted/rest blending first, then adds the layers.
Additive weights stay independent and are not normalized against other layers
or the normal actions. A layer with no normal action applies over the captured
rest pose, including each morph primitive's independent rest weights. Stopping
the last owner restores that rest pose. Cubic interpolation is sampled before
computing offsets, preserving the original quaternion signs and tangent rates.

The complete combined pose is validated before publication. A singular final
scale, nonfinite value or out-of-range morph weight rejects the update without
changing any node, playhead, repeat count or completion event. Zero-weight
layers still own their channels and advance their clocks when playing, just as
normal zero-weight actions do.

The reference-pose convention follows
[Three.js additive conversion](https://github.com/mrdoob/three.js/blob/dev/src/animation/AnimationUtils.js).
Here, each action stores its reference samples and the immutable clip stays
usable by other model instances and normal playback.

## Fades, cross-fades and speed transitions

You can fade a held additive pose, move smoothly between clips, or ease playback
to a stop:

```dart
lean.fadeTo(.8, const Duration(milliseconds: 300));
lean.fadeOut(const Duration(milliseconds: 500));

final reach = mixer.play(reachClip, weight: 0)..pause();
swing.crossFadeTo(reach, const Duration(milliseconds: 750), warp: true);
reach.halt(const Duration(seconds: 1));
```

All transitions are linear and use mixer time. They continue while the playhead
is paused or finished, so you can fade a held pose without moving along its
clip. Each action holds at most one fade and one speed transition. Scheduling
another replaces the previous transition. Durations accept zero through one
billion seconds; zero applies the endpoint immediately.

| Control | Behaviour |
| --- | --- |
| `fadeTo(weight, duration)` | Starts from the current weight; optional `pauseWhenDone` defaults to false |
| `fadeIn(duration, weight: 1)` | Starts at zero weight and reaches the supplied weight; preserves playhead pause |
| `fadeOut(duration, pauseWhenDone: true)` | Reaches zero weight, then pauses the playhead by default |
| `stopFading()` | Keeps the current weight and cancels the fade |
| `warp(startSpeed, endSpeed, duration)` | Sets the starting speed and integrates the linear speed curve |
| `warpTo(speed, duration)` | Starts from the current speed |
| `halt(duration)` | Changes speed smoothly to zero |
| `stopWarping()` | Keeps the current speed and cancels its transition |
| `isFading`, `isWarping` | Reports whether each transition remains active |

`crossFadeTo(target, duration)` fades the source from its current weight to zero
and the target from its current weight to `targetWeight` (default one). It resumes
the target, restarting it if finished, and pauses the source at the fade endpoint.
`target.crossFadeFrom(source, duration)` performs the same operation. Both
unstopped actions must belong to one mixer. The source remains reusable at zero
weight; call `stop` when you no longer need its bindings.

With `warp: true`, both clips must have positive durations. The source speed
changes from its current value to `target.speed * source.duration / target.duration`.
The target starts at `source.speed * target.duration / source.duration` and ends
at its original speed. This matches rates measured in clip traversals per second;
it preserves existing phases. Calculated speeds must still fit `[-1024, 1024]`.
Without warping, each action retains its own speed and any existing speed transition.

The mixer commits both sides of a cross-fade together. Invalid poses leave all
weights, transition progress, clocks and events unchanged. Speed curves are
integrated across each step, splitting at reversals so a clip can finish before
the direction changes. A fade that pauses halfway through a large update advances
the playhead only as far as that fade endpoint. Unrelated speed transitions can
continue after the playhead pauses.

New transitions skip their first automatic frame delta to ignore time spent idle.
Already running playheads keep advancing. Reattaching a mixer skips that first
delta for both clocks and transitions; explicit `update` calls advance immediately.
Transitions release frame demand when finished, provided no playhead still needs
it. Fades do not emit loop or completion events.

The control names follow [Three.js AnimationAction](https://threejs.org/docs/pages/AnimationAction.html).
This API uses absolute weights and speeds and keeps atomic mixer validation.

## Finite playback and events

To play a clip three times and react to natural completion, subscribe before
calling `play`:

```dart
final subscription = mixer.events.listen((event) {
  switch (event) {
    case AnimationFinishedEvent(:final action):
      action.stop(); // Release its held pose, or play a successor here.
    case AnimationLoopEvent(:final repetitionsDelta):
      print('Crossed $repetitionsDelta clip boundaries');
  }
});
final action = mixer.play(clip, repetitions: 3);
// Cancel the subscription when its owning screen or model is disposed.
```

`repetitions` accepts 1 through one billion. Null keeps repeating. Each ping-pong
leg counts as one traversal, so two legs return to the starting endpoint.
`once` always performs one traversal, regardless of this option. A finished
action retains its final contribution and releases frame demand. Reverse
repeat ends at zero; forward repeat ends at the clip duration.

Events are asynchronous broadcast snapshots. Each carries `action`, local
`time`/`timeSeconds`, `completedRepetitions` and playback `direction` (`-1` or
`1`, independent of ping-pong reflection). A time step produces at most one
event per action: a loop event with the number of crossed boundaries, or a
finished event if that step completes playback. Listening code can change
playback without mutating the mixer during pose evaluation. The snapshot stays
fixed even if its action has since advanced, restarted or stopped.
When a speed curve reverses, a loop snapshot reports the last playback segment's
direction. A completion snapshot keeps the direction that reached the endpoint,
even if the speed transition changes sign later in that same update.

A zero-duration clip finishes during `play`, with zero completed traversals.
Subscribe first to receive that event. No frame is needed. Seek, pause, stop and
configuration edits never synthesize completion events. Seeking resets the
completed count and ping-pong phase; resuming after a pause retains them, while
resuming a finished action starts a fresh run. Loop edits reset phase and count;
repeat-count edits preserve phase and reset only the count. Editing a finished
action leaves it paused until you resume it.

All poses, counters and completion states commit together. A failed track sample
leaves the previous state intact and emits no event. Boundary arithmetic allows
only floating-point roundoff so split elapsed steps can land on fractional clip
ends. Finite clips clamp before counting unused excess elapsed time; an
unlimited step that would exceed the exact counter range of `2^53 - 1` is
rejected before publication.

The traversal and batched loop-event model follows the
[Three.js animation action](https://threejs.org/docs/pages/AnimationAction.html).
This Dart API keeps its existing held final pose and publishes typed events
after committing the complete mixer update.

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

The two scene hierarchies share clips and immutable geometry. Each has a paused
lean layer over its main motion; the layer-strength slider affects only the
selected model and does not hold frame demand when idle. You can fade that layer,
blend between Swing and Reach with matched playback rates, and slow the selected
action to a stop. The controls reuse actions for repeated blends. This is transform
animation. Native GPU instancing, skinning and morph deformation use the
[deformation API](deformation.md). glTF transform and morph-weight import use
these same tracks. Custom shader deformation, per-instance colors and remaining
renderer qualification are tracked separately in the implementation plan.
