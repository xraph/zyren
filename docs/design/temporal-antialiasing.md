# Temporal antialiasing

Attach one temporal plugin to your view and use single-sample HDR:

```dart
final temporal = TemporalAntialiasing(
  options: TemporalAAOptions(historyWeight: .9, maxBytes: 128 * 1024 * 1024),
);
final controller = SceneController(colorPipeline: ColorPipeline());
controller.use(temporal);
controller.use(PostProcessing(bloom: BloomOptions()));
```

You can change `options`, toggle `enabled`, or call `reset()` without recreating
its renderer. `SceneEngine.invalidateHistory()` also resets temporal AA. The
plugin requests eight accepted frames after a scene or camera change, then lets
a demand-driven view sleep. Rejected frames do not count toward convergence.

The native scene uses eight centered Halton offsets. A motion pass evaluates
current and previously accepted model, instance, morph and skin state on the GPU.
Motion uses unjittered projection matrices; scene rasterization uses the jittered
matrix. Reconstruction runs in linear HDR before graph effects and tone mapping.
History stores alpha-associated color, while graph effects receive straight color.

A 3x3 neighborhood supplies color bounds and nearest-surface motion at edges.
Reprojected depth rejects newly exposed surfaces. Neighborhood clipping limits
stale color, and transparent or depth-disabled overlays reject history. Alpha
masks use the same texture, vertex opacity and cutoff as the scene draw.

Each object has a stable identity. Removed objects and newly visible objects
cannot borrow another mesh's pose. CPU geometry revisions and material edits
reject that mesh's history. Instance transforms, morph weights and skin poses
retain motion history; changed instance colors reject the affected instance.

Resize, projection changes, camera replacement and explicit resets restart the
sequence. The automatic camera-cut heuristic also resets for a forward-direction
change above 45 degrees or translation above half the smaller target distance.
Call `reset()` for a cut that doesn't cross those thresholds.

## Profile and memory

This profile accepts built-in triangle materials, including physical materials,
instancing, skinning and morphs. Custom mesh shaders, lines, points and four-sample
MSAA return an error when temporal AA is enabled. Transparent overlays render
correctly but do not accumulate temporal coverage. Moving highlights and changing
lighting can still leave short trails within the clipping bounds.

A view retains two RGBA16F color histories, two R32F depth histories and two sets
of previous vertex, instance and deformation buffers. Shared working color, depth
and motion targets add 28 bytes per pixel. Once both histories exist, attachments
consume 52 bytes per pixel for one view, before retained mesh data. Additional
views share the working targets and retain their own histories.

`TemporalAAOptions.maxBytes` defaults to 128 MiB per view, including shared working
targets and replacement overlap. Temporal allocations also have a 256 MiB device
limit. The RGBA32F motion attachment has a 64 MiB limit. Admission precedes scene
uploads, so a rejected resize or budget edit preserves accepted history.

Use `NativeGpuBackend.temporalStats()` for device-wide temporal payload bytes and
history-view count. These allocations are separate from `resourceStats()`, shadow
atlases, frame targets, fixed fallback textures, transient uniforms and driver
padding. Disabling temporal AA or closing the last view releases the histories
and working targets. Pipeline objects remain cached with the renderer.

## Checks

Metal readback fixtures compare diagonal edges with an 8x supersampled reference,
check exposed background after motion, and exercise masked, blended, mirrored,
skinned and morphed meshes. A GPU motion-buffer check verifies zero velocity for
stationary geometry despite jitter, the numerical velocity of a translated mesh,
and preservation of accepted state after budget rejection. Repeated frames,
independent views, resize, projection changes and cleanup have regression tests.

The post-processing gallery includes a Temporal AA toggle. Selecting it switches
to one sample; selecting 4x MSAA disables temporal AA. These are exclusive scene
coverage modes. Bloom and spatial AA can follow either one.
