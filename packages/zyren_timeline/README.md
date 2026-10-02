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
consumed start state for renderer recovery. Reverse playback, clip mixing,
imported animation events, skeletal animation and morphs are outside this version.
