# zyren_timeline

Scrub and play absolute object transforms or camera poses, with named playback
markers.

```dart
final timeline = SceneTimelinePlugin(
  duration: const Duration(seconds: 2),
  tracks: [
    TransformTrack(mesh, [
      TransformKeyframe(Duration.zero),
      TransformKeyframe(
        const Duration(seconds: 2),
        position: const Vec3(2, 0, 0),
      ),
    ]),
  ],
);
controller.use(timeline);
await controller.ready;
timeline.seek(const Duration(seconds: 1));
timeline.play();
```

Transform keyframes describe complete local poses, including scale, rotation and
visibility. Position and scale interpolate linearly. Rotations follow the shortest
quaternion arc; visibility changes at its keyframe. Scale cannot cross zero.
Use `CameraTrack` and `CameraKeyframe` for world-space position, target and up.

`seek` clamps to the clip range and preserves playback state. `play` restarts a
finished clip. Pause releases frame demand; detach pauses without restoring the
old pose. Looping retains the time left over after the end of a clip. The engine's
capped delta prevents a long background pause from advancing the full gap.

Keep one writer in control of each tracked object or camera during playback.
For example, pause orbit controls while a camera track runs. Targets must stay in
their attached scene and parent, and camera tracks must use the engine's camera.
Invalid targets or sampled poses stop playback and report an error.

You can implement `TimelineTrack` for another property. `prepare` must validate
without mutation and return an edit that cannot fail. Built-in tracks are sampled
before any edits are applied. Do not reuse a target across multiple tracks.

## Mixing clips

Use `SceneTimelinePlugin.mixed` when several clips contribute to the same pose:

```dart
final base = TimelineClip(
  duration: const Duration(seconds: 2),
  tracks: [TransformTrack(mesh, [TransformKeyframe(Duration.zero)])],
);
final raised = TimelineClip(
  duration: const Duration(seconds: 2),
  tracks: [
    TransformTrack(mesh, [
      TransformKeyframe(Duration.zero, position: const Vec3(0, 2, 0)),
    ]),
  ],
);
final lift = TimelineLayer(
  clip: raised,
  weights: [
    ClipWeight(Duration.zero, 0),
    ClipWeight(const Duration(seconds: 1), 1),
    ClipWeight(const Duration(seconds: 2), 0),
  ],
);
final timeline = SceneTimelinePlugin.mixed(
  duration: const Duration(seconds: 2),
  base: base,
  layers: [lift],
);
controller.use(timeline);
await controller.ready;
timeline.seek(const Duration(milliseconds: 500)); // mesh.position.y == 1
```

Clips copy their built-in `TransformTrack` and `CameraTrack` data. Custom tracks
and subclasses are rejected. A layer may omit base targets, but every target it
includes must have the same track type as its base. Track lists and weight keys
are immutable.

Weight keys use the main timeline's clock, fit its duration, increase strictly
and have values from zero to one. Endpoint weights hold outside the keys. You
can query the curve with `layer.weightAt(time)`. A nonnegative `start` shifts the
clip's local sampling time without shifting its weight curve. Clip time clamps
to its endpoints; clips can have different durations from the main timeline.

The base supplies unused weight separately for each target. If active layer
weights exceed one, they normalize and the base contributes nothing. Positions
and scales average linearly. Active scales must keep matching signs on every
axis. Across clips, quaternion signs align to the highest-weight pose before
normalized linear blending; this differs from the spherical interpolation used
within a track. Visibility comes from the highest-weight pose, with ties going
to the base, then layers in declaration order. Camera positions, targets and
normalized up vectors blend before validating the resulting view.

Inactive tracks are not sampled. Invalid active samples or blends leave every
target and the timeline position unchanged, pause playback and emit no events
for that advance. Targets retain the normal scene and parent ownership checks.
Markers stay on the main timeline, so blending does not duplicate them.

## Playback events

Pass `markers` alongside your tracks and listen to `events`:

```dart
final timeline = SceneTimelinePlugin(
  duration: const Duration(seconds: 2),
  tracks: [],
  markers: [
    TimelineMarker(Duration.zero, id: 'start', label: 'Assembled'),
    TimelineMarker(const Duration(seconds: 1), id: 'separating'),
    TimelineMarker(const Duration(seconds: 2), id: 'end', label: 'Exploded'),
  ],
);
final subscription = timeline.events.listen((event) {
  print('${event.marker.id}: loop ${event.loopIndex}, pose ${event.position}');
});
// Attach the plugin before playing. Cancel the subscription when you're done.
```

Keep marker times in order, within the clip, and use unique, nonempty IDs. Equal
times fire in declaration order. The plugin copies the marker list.

Playback emits each marker crossed in `(previous, next]`. Starting at zero also
emits zero-time markers; pause/resume does not repeat them. At a loop boundary,
end markers fire before the next loop's zero-time markers. Events include the
zero-based loop index and the sampled position after the advance. One frame can
cross several markers or loops.

Scrubbing is silent. `seek` resets the loop index, and seeking to zero arms the
start markers for the next playback advance. Playing a finished clip restarts it.
Notifications arrive asynchronously after the pose update, so event handlers
cannot interrupt track sampling. When a handler runs, the scene may have already
advanced; use the record's position when you need that advance's sampled time.
You can use an empty track list for a clip that only carries events.

`maxEventsPerAdvance` defaults to 1,024. If a start or advance would exceed it,
playback stops with a `StateError`, keeping its earlier pose and position. No
markers from that advance are emitted. Increase the limit for intentionally dense
clips. Invalid track samples follow the same event behavior.

The exported `sceneTimeline` service key belongs to `zyren.timeline`. Cancel your
`changes` and `events` subscriptions when their consumers close. Pausing a stream
subscription can buffer notifications. Detach stops playback and retains the
consumed start state for renderer recovery. Imported model channels and events use the optional `zyren_gltf_timeline` adapter.


## Independent actions

After attaching a mixed timeline, you can run clips on separate clocks:

```dart
final idle = timeline.createAction(idleClip, weight: 1)..play();
final walk = timeline.createAction(walkClip);
idle.crossFadeTo(walk, const Duration(milliseconds: 250));
```

Actions share the base targets and use the same normalized pose mixer as authored
layers. `createAction` starts paused at zero weight unless you specify a weight.
`play` restarts a finished action. `pause` holds its current pose, and `seek`
clamps its local clock without moving the main timeline or emitting markers.
An action holds its final pose at completion. Call `dispose` to remove its
contribution and invalidate its handle.

Use `fadeTo(weight, duration)` to change a contribution. A fade continues while
its action clock is paused, and interruption starts from the current weight.
`crossFadeTo` starts the destination without resetting an unfinished clock and
fades the source to zero. The source clock continues until its endpoint or until
you pause it. Crossfades require positive duration and actions on the same timeline.

Action clocks and fades use the engine delta. They acquire their own frame demand,
so you can keep the main timeline paused. Detach stops actions and invalidates
handles. Failed blends keep the previous scene pose and clocks, stop playback
and cancel fades. Action clips do not emit markers; markers use the main clock.

## Imported animation

Use the optional `zyren_gltf_timeline` package to play imported glTF TRS, skin
and morph channels. It binds one custom track to a `ModelInstance` and maps
`extras.zyrenEvents` to main-clock markers. The importer and timeline remain
independent; you only add the adapter when you need imported playback.

Use `modelClip(instance, animation)` and `modelRestClip(instance)` to mix imported
poses through authored layers or runtime actions. The adapter blends joint TRS
and morph weights before one CPU deformation and native dynamic-geometry upload.
Imported actions support crossfades, additive references, loops and reverse
playback. GPU skinning and morph kernels are not implemented.

You can extend the mixer with `BlendableTimelineTrack`. Return an immutable
snapshot that preserves its target and duration, and accept only compatible
tracks in `canBlendWith`. `prepareBlend` receives normalized absolute samples
and ordered additive samples with reference times. It must validate the whole
result without changing scene state, then return one infallible apply closure.
The mixer prepares every target before applying any edits. Custom tracks are
responsible for declaring all state they own through their target and keeping
other writers away from that state.

## Local looping and reverse playback

Set `loop: true` on a `TimelineLayer` to repeat its clip independently of the main
clock. `reverse: true` samples from its end toward zero. The layer holds its
starting endpoint before `start`. A looping reverse layer samples the end at
an exact loop boundary; a forward layer samples zero. You can inspect the mapping
with `localTimeAt(time)`. Weight curves always use the main clock.

Actions accept the same `loop` and `reverse` options. Reverse actions start at
the clip end, retain overshoot across loops and stop at zero when looping is off.
You can change either flag during playback. Their fades keep moving forward in
elapsed engine time even when their clip clocks run backward. `sampleTime` on
an authored layer fixes its local sample and overrides loop/reverse mapping.

The main timeline also accepts `reverse: true`. Reverse playback starts at the
end, emits markers in descending time order and keeps equal-time markers in
declaration order. It crosses `[next, previous)`, including end markers when
starting at the end. A reverse loop emits zero markers before the next loop's
end markers. Seeking is still silent, and the event limit applies in either
direction. Set the direction before seeking to its starting endpoint if you
want to rearm that endpoint's markers.

## Additive layers

Set `additive: true` on a layer or action to apply changes relative to its clip's
`referenceTime`, which defaults to zero. Additive weights do not consume or
normalize absolute layer weights. The mixer first resolves absolute poses, then
applies additive layers in declaration order, followed by actions in creation
order. This keeps seeking deterministic.

Position deltas add in the target's parent space. Rotation uses a local quaternion
delta from the reference orientation, interpolated from identity and multiplied
onto the blended rotation. Scale applies a weighted sample/reference ratio on
each axis. Its signs must match the reference, and the resulting pose must stay
finite and nonsingular. Visibility stays with the absolute blend.

Camera position, target and normalized up deltas add relative to the reference
camera pose. The final view still passes camera validation before any scene edits.
Choose a reference pose that represents no contribution. A constant clip sampled
at its reference adds nothing.
