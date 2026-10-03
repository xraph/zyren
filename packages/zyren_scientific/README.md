# zyren_scientific

Render scalar slices, isosurfaces, irregular surfaces, vector glyphs, streamlines
and volumes through Zyren's native backend. You supply the values, units and
source identity. Versioned temporal sources support discrete and linear sampling.
The package visualizes supplied results; it does not solve a physical model or
certify a measurement.

Start with the [Flutter lab](example/flutter). It uses native presentation,
compact controls and the shared ZeroState. The synthetic fields make it easy to
compare a slice with its isosurface or volume, change time, and inspect a pick.

```dart
import 'package:zyren/zyren.dart';
import 'package:zyren_scientific/zyren_scientific.dart';

final temperature = ScientificUnit(quantity: 'temperature', symbol: 'K');
final field = ScalarGrid3D(
  sizeX: 2, sizeY: 2, sizeZ: 2,
  values: [273, 283, 293, 303, 283, 293, 303, 313],
  origin: Vec3.zero,
  spacing: const Vec3(.1, .1, .1),
  valueUnit: temperature,
  coordinateUnit: ScientificUnit(quantity: 'length', symbol: 'm'),
  source: ScientificSource(
    id: 'synthetic:temperature:v1',
    description: 'Synthetic temperature fixture',
    kind: ScientificDataKind.synthetic,
  ),
  name: 'Temperature',
);
final transfer = ScalarTransferFunction(
  unit: temperature, minimum: 273, maximum: 313,
  stops: [
    TransferStop(0, const Color3(0, 0, 1)),
    TransferStop(1, const Color3(1, 0, 0)),
  ],
);
final surface = await extractIsosurface(
  grid: field, threshold: 293, transfer: transfer,
  coordinateTolerance: 1e-6,
);
final mesh = surface.createMesh();
if (mesh != null) scene.add(mesh);
```

Use your existing `Scene` for `scene`. Remove the mesh when its view closes.
`ScientificFieldView` handles replacement, revision checks and disposal when you
need to switch representations. `ScientificSliceView` remains available for an
independent X, Y or Z slice.

## Data, surfaces and precision

X varies fastest, then Y, then Z. Scalar grids copy values into float64 storage
with an explicit validity mask. Null means missing; zero is valid. NaN, infinity,
invalid extents and excessive dimensions fail validation before owned allocation.
Quantity and unit symbol must match exactly. You perform any unit conversion.
Coordinates require a `length` quantity.

`sampleScalar` performs trilinear interpolation in coordinates relative to the
grid origin. It reports valid, missing or outside. Zero-weight corners do not
contribute to missing status. Fractional slices interpolate between grid planes;
an exact slice uses only its own plane. Missing corners omit whole slice cells.

Isosurfaces use six tetrahedra per cell with a consistent body diagonal. Shared
edges reuse vertices, including exact threshold endpoints. Equality belongs to
the low side, normals point toward increasing scalar values, and a missing corner
omits the entire cell. `sourceCells` maps each output triangle to its stable,
X-fast source cell ID. This is a piecewise linear tetrahedral surface; a
trilinear source query at the same point can return a different scalar value.

Use `ScientificSurface.build` for irregular triangle connectivity. Choose vertex
or cell scalar association. Cell values produce flat triangle colors. Invalid
indices and degenerate triangles fail validation; missing values omit affected
triangles. Both builders support cooperative `ScientificCancellation`.

Geometry retains the double-precision origin in its mesh transform and measures
local float32 position conversion error against `coordinateTolerance`. Collapsed
triangles and line segments fail validation. The tolerance excludes world
transform arithmetic, projection and rasterization. It is not an accuracy claim
about your source measurements.

Transfer stops contain linear RGB. Values outside the declared range clamp, and
a constant range maps to the midpoint. Meshes interpolate mapped vertex colors;
volumes evaluate the transfer at each ray sample. Unlit materials preserve
transfer colors before your host's tone mapping and postprocessing.

## Vectors and streamlines

`VectorGrid3D` holds three scalar component grids with matching dimensions,
source, units and coordinates. Supply a right-handed orthonormal `VectorBasis`.
`VectorBasis.cartesian()` uses the grid axes. Samples return vectors in those
coordinate axes, with explicit missing/outside status.

```dart
final path = await integrateStreamline(
  field: vectors,
  seed: const Vec3(.4, 1, 1), // Relative to vectors.x.origin.
  options: StreamlineOptions(
    initialStep: .05, minStep: 1e-5, maxStep: .1,
    maxLength: 10, tolerance: 1e-5, stagnation: 1e-12,
  ),
);
```

Here `vectors` is your `VectorGrid3D`. RK4 step doubling adapts the step using the
coordinate error tolerance. Integration follows normalized vectors by arc length,
so step and length use coordinate units. Stagnation uses the vector magnitude
unit. Choose `reverse: true` to trace backward. This is a steady-field streamline,
not a pathline through evolving velocity data.

Results retain local points, accepted length, maximum step error, attempt count
and a termination reason: length, domain, missing data, stagnation, tolerance or
work limit. A boundary stop retains the last accepted point. `path.geometry`
creates native line segments; `buildVectorGlyphs` creates arrow shafts and heads
with deterministic grid strides. Glyph length scale is coordinate length per
vector unit. Excessive counts fail instead of silently thinning your data.

## Temporal sources and playback

`TemporalScalarSource` takes strictly ordered `ScientificFrameKey` entries and a
loader. Each key has an ID, version and time; the source declares its time unit.
A newer seek cancels the previous request. Loaders run serially and should observe
the supplied cancellation token so external work can stop promptly.

The cache retains at most two source frames, within its payload limit. Returned
interpolated grids and storage owned by your loader are separate allocations.
Linear interpolation requires matching layouts, source identity and units, and
preserves missing contributing samples. Discrete interpolation selects the
preceding frame. Exact frame times use that frame alone. Requests outside the
source time range fail; loader errors propagate without publishing a new view.

Import `package:zyren_scientific/timeline.dart` for `ScientificSliceTrack`. It uses
a loaded `TemporalScalarWindow` and a stable scene parent. Add it to the shared
`SceneTimelinePlugin` to reuse playback, seeking and frame demand. Preparation
builds a candidate without editing the scene. Dispose the track when your host
unloads its geometry, and dispose the timeline through its owning engine.
The adapter rejects time spans that collapse below its microsecond clock precision.

Temporal scalar changes do not animate an independent static vector field. Agent
metadata reports the two sources and their time status separately.

## Native volume rendering

Attach `ScientificVolumePlugin` to your engine before rendering, then call its
controller's `setVolume` with `ScientificVolumeSettings`. The plugin owns scoped
GPU resources and updates camera-relative bounds and clipping planes before each
frame. A null setting removes the effect. Failed candidates close their resources
and leave the active effect intact.

`VolumeTransferFunction` maps scalars to linear RGB and opacity. Opacity is defined
per `referenceDistance`, in the grid's coordinate length unit. The ray marcher
uses `1 - pow(1 - opacity, step / referenceDistance)` at each step, including the
last partial step. It composites in premultiplied HDR and terminates when residual
transmittance falls below approximately 1/65536.

Rays intersect the axis-aligned grid, the camera's near/far interval, up to six
shared scene clipping planes, and opaque scene depth. Standard and reversed depth
are supported. The camera may be inside the volume. Transparent-object depth and
physically ordered interleaving of multiple overlapping volumes are outside this
single-volume effect's compositing contract.

The 3D RGBA32F texture stores scalar values and validity. Trilinear sampling uses
explicit texture loads, so it does not require float32 filtering support. Missing
contributing voxels produce transparent samples. Uploads check `scalarTolerance`;
lengths and camera-relative bounds check `coordinateTolerance`. Values that cannot
fit those float32 tolerances fail explicitly. Resources close after cancellation,
failed compilation or plugin detachment.

## Resource limits

| Work | Limit |
| --- | --- |
| Scalar grid | 1,000,000 samples; 9 typed bytes per sample |
| Slice or extraction input | 250,000 cells |
| Surface/line output | 16 MiB conservative geometry and identity payload |
| Vector glyphs | 20,000 requested glyphs |
| Streamline | 100,000 attempts and 100,000 points; defaults are 20,000 |
| Temporal cache | Two source frames, up to 18,000,000 payload bytes |
| Volume | 256 samples per axis, within the scalar-grid sample ceiling |
| Volume ray | Up to 4,096 steps; default ceiling 1,024 |
| Volume viewport | Default 256 million pixel-sample upper bound; hard ceiling 512 million |

You can lower `ScientificBudget` and the work-specific limits. Typed payload
limits exclude caller storage, VM overhead, temporary copies and native copies.
They do not measure physical GPU residency. Each vector component retains its
own scalar payload. Isosurface source-cell IDs contribute to the output budget.

## Undo and session history

Both views retain a bounded undo/redo history. The field view establishes its
baseline on the first successful `configure`; later commits record settings and
immutable source data. A temporal undo restores the original versioned values
without reloading the source. Geometry and GPU resources are rebuilt on demand.

```dart
await view.undo(expectedRevision: view.revision);
await view.redo(expectedRevision: view.revision);
print(view.history); // Counts, labels, retained payload and configured limits.
await view.clearHistory(expectedRevision: view.revision);
```

Use `canUndo` and `canRedo` to enable controls. Empty undo/redo returns false and
keeps the revision. Successful operations advance it. Failed, cancelled or stale
operations leave history untouched; a new successful edit discards redo.
`configure(clearTime: true)` returns to the original static grid and is undoable.

The default is 32 entries and 32 MiB of conservatively counted source/settings
payload. Set `historyLimit` and `historyByteLimit` to lower these limits or disable
history with zero. Hard ceilings are 256 entries and 64 MiB. Payload accounting
excludes VM overhead, loader caches, temporary geometry and native copies. Closing
a view releases its history. History is session-local and has no disk persistence.

## Accessible Flutter controls

The lab provides Undo/Redo buttons and Ctrl/Cmd+Z, with Shift for redo. A slider
drag commits one history entry when you release it. Agent changes refresh the
same controls, including thresholds outside the usual demonstration range.

Use Camera controls for labelled rotation, zoom and reset buttons. Sample source
opens an inline panel with adjustable X/Y/Z coordinates and a live scalar/vector
readout. You can inspect source values without pointing at geometry. Controls
wrap and scroll at narrow widths and large text sizes while retaining canvas
space. Focus order follows the visible controls; sliders announce their units.

The example uses 0.1 m volume sampling, matching its synthetic grid spacing. This
keeps a full-resolution iPad canvas within the existing pixel-sample work limit.
Its iOS host keeps the screen awake while the lab is foregrounded.

## Runtime agents

Import `package:zyren_scientific/agents.dart` and register your `ScientificFieldView`
with `registerScientificField`. The `zyren.scientific.field` provider exposes:

| Tool | Behavior |
| --- | --- |
| `inspect` | Active source, representation, units, versions, missing counts and errors |
| `sample_position` | Trilinear scalar and available vector data at a local coordinate |
| `sample_triangle` | Join a shared viewport pick to source data and isosurface cell identity |
| `set_representation` | Build and display a slice, isosurface, vectors, streamline or volume |
| `set_parameters` | Threshold, slice index, seed, glyph scale and volume sampling controls |
| `set_transfer` | Scalar range in the existing unit |
| `seek` | Temporal source seek, when a source is attached |
| `history` | Read undo/redo counts, labels and retained payload |
| `undo`, `redo` | Restore a committed source and configuration |
| `clear_history` | Release all retained undo/redo entries |

The host grants `scientific.edit`. Mutations require an expected revision and an
idempotency key; cancellation is checked before committing prepared work.
Disposal removes registered agent access and owned geometry. Pass the provider's
`metadata` callback to the shared `AgentViewportProvider`. Triangle joins verify
object and scene identity, and keep pixel visibility unknown. Lines and volumes
use source-position queries. The host owns screen/frame correlation and policy.
The independent slice provider exposes the same four history tools alongside its
six slice tools. All history mutations use the same editing scope and retry rules.

## Verification and examples

Use the SDK pinned in `.fvmrc`. Run package checks from this directory so Dart
loads the native build hook:

```sh
RUN_NATIVE_GPU=1 dart test --reporter expanded
flutter analyze --no-pub
dart run example/synthetic_slice.dart /tmp/zyren-scientific-evidence
python3 example/verify_mcp.py /path/to/flutter/bin/dart /tmp/zyren-scientific-evidence/mcp
python3 example/verify_field_mcp.py /path/to/flutter/bin/dart /tmp/zyren-scientific-evidence/field-mcp
```

The MCP examples reuse `serveDevtoolsMcp` and `AgentDevtoolsBridge` over stdio.
They start no network listener. Their hosts explicitly grant editing and capture
real native images after commands. These images are offscreen evidence.

From `example/flutter`, run `flutter test --no-pub -d <device>
integration_test/scientific_test.dart` for numerical GPU checks and native
presentation checks. The lab requires native presentation, so an unsupported
platform fails visibly without choosing a browser or readback fallback.

See [qualification](qualification/2026-10-02.md) for measured errors, Metal and
Vulkan device results, and remaining platform limits. Windows DX12 and Linux
remain unqualified. The current shared Flutter plugin registers Android, iOS and
macOS platforms; generated desktop runners alone do not add a Windows/Linux
presenter. This package has not been published.
