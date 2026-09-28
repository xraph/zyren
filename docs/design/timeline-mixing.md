# Timeline clip mixing

Use `SceneTimelinePlugin.mixed` to combine a base `TimelineClip` with weighted
`TimelineLayer` clips. Each clip contains immutable built-in transform or camera
tracks. A layer can target a subset of the base clip's objects, but it cannot add
an object or change its track type. The base supplies every target's fallback.

You author each layer's weight with ordered `ClipWeight` keys on the main
timeline. Values range from zero to one and interpolate linearly. Before and
after the weight keys, their endpoint values hold. A layer's `start` shifts its
clip's local time; sampling clamps to that clip's endpoints. It does not shift
the weight keys. Clip duration and the main timeline duration can differ.

For each target, sum the weights of layers that contain that target. When the
sum is below one, the base contributes the remainder. Above one, normalize the
layers and give the base zero weight. No layer has weight? Use the base pose.
Zero-weight tracks are not sampled, so an inactive layer cannot fail a frame
because of its camera pose.

Positions and scale use a weighted average. Active scale values must have the
same sign on each axis, keeping reflection changes from collapsing a mesh.
Rotations within a clip keep shortest-arc spherical interpolation. Across clips,
align quaternion signs to the highest-weight pose, then normalize their weighted
sum. This is normalized linear quaternion blending; it does not promise constant
angular speed. Visibility comes from the highest-weight pose. Ties favor the
base, then layers in declaration order. Quaternion reference ties use that order
too. Camera position, target and up blend linearly, and the result must remain a
valid camera pose.

Sampling validates every result before applying edits. Invalid blends pause
playback, release frame demand and preserve the previous pose, time and events.
All existing target-scope and reparenting checks apply. Detach preserves the last
pose. Use one writer for the tracked objects, including the camera.

Markers belong to the main timeline. Layers do not dispatch independent events,
so a crossfade cannot duplicate notifications. Seek stays silent, loop boundaries
keep their current ordering, and frame demand still belongs to one plugin.
This milestone covers authored absolute blending. Additive clips, independently
playing actions, runtime crossfade commands, per-layer looping, skeletal tracks
and morph tracks need separate contracts.

The workbench adds a lift clip over its straight exploded-assembly clip. Its
weight rises to one halfway through playback and returns to zero at the end.
The same seek slider previews the blend; a compact weight label makes the active
mix visible. Tests cover numerical poses, sparse layers, timing, quaternion signs,
visibility ties, singular blends, atomic failure, ownership and events. Native
Metal playback and desktop/narrow layouts complete the workbench check.
