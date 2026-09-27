# zyren_timeline

Scrub and play absolute object transforms or camera poses.

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

The exported `sceneTimeline` service key belongs to `zyren.timeline`. Cancel your
`changes` subscription when its consumer closes. Skeletal animation, morphs and
event tracks are outside this version.
