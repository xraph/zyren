# zyren_scientific

Use `zyren_scientific` to validate a scalar grid and render an axis-aligned slice
through Zyren's native backend. You supply the values, units and source identity.
The package visualizes your data; it does not run a physical solver or certify a
measurement.

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
final slice = ScalarSlice.build(
  grid: field, transfer: transfer,
  axis: SliceAxis.z, index: .5, coordinateTolerance: 1e-6,
);
final view = ScientificSliceView(
  id: 'temperature', scene: scene, slice: slice, coordinateTolerance: 1e-6,
);
// Use the same revision-checked operation from your UI or agent adapter.
view.setSlice(axis: SliceAxis.z, index: 1, expectedRevision: view.revision);
// When the host unloads this view:
view.dispose();
```

Declare `scene` as your existing Zyren `Scene`. If you only need immutable
geometry, use `slice.geometry` or `slice.createMesh()`. An empty slice returns no
mesh. Your host can present that state through its shared ZeroState component.

## Data and numerical behavior

X varies fastest, then Y, then Z. Samples use float64 storage. Null means missing;
zero is valid. The constructor copies your values and rejects NaN, infinity,
invalid extents and over-budget inputs before allocating its sample arrays.

Use the same quantity and unit symbol for the field and transfer function.
Conversions belong to your data preparation. Coordinates require a unit whose
quantity is `length`; no code assumes that every scene uses metres.

Slice indices are grid coordinates, so `z = 1.5` lies halfway between planes 1
and 2. Integer slices only consult their own plane. Fractional slices need both
contributing samples, and a missing corner removes the whole cell. You can read
`omittedCells`, `belowRangeSamples` and `aboveRangeSamples` to explain the image.

Transfer stops contain linear RGB, with strictly increasing positions including
0 and 1. Values outside the declared range clamp to its endpoints. A constant
range maps to the midpoint. The renderer interpolates mapped colors over each
triangle; nonlinear transfer functions are sampled at vertices, not evaluated
per fragment. Unlit materials prevent lighting from changing the scalar colors.
Your host's tone mapping and postprocessing can still change the final image.

The mesh transform retains the double-precision origin. Local positions use
float32, and `coordinateTolerance` limits their measured absolute conversion
error in your coordinate unit. Collapsed neighboring coordinates are rejected.
This tolerance excludes world-transform arithmetic, projection and rasterization.
It is not a measurement-accuracy claim.

Default hard ceilings are 1,000,000 samples, 250,000 slice cells and 16 MiB of
geometry payload. You can lower them with `ScientificBudget`. A grid retains
nine typed bytes per sample. Slice preflight uses `36 * vertices + 24 * cells`
bytes, even when missing data later removes cells; temporary geometry copies,
caller-owned data, VM overhead and native copies consume additional memory.
Reported payload bytes do not measure physical GPU residency. You own scene and
backend teardown; the slice does not allocate a separate GPU scope.

## Runtime agents

Import `package:zyren_scientific/agents.dart` to use the shared registry. The host
chooses its granted scopes. Read-only hosts can omit `scientific.edit`.

```dart
final registry = AgentRegistry(grantedScopes: {'scientific.edit'});
final registration = registerScientificView(registry, view);
final provider = ScientificAgentProvider(view);
// Pass provider.metadata to your AgentViewportProvider metadata callback.
// Dispose registration to remove agent access without removing the view.
```

Import `package:zyren_agents/zyren_agents.dart` for `AgentRegistry`. Discovery
publishes the schemas and limits for these tools:

| Tool | Behavior |
| --- | --- |
| `inspect` | Source, dimensions, units, missing counts, active slice and transfer |
| `sample` | One integer u,v slice sample, with explicit missing status |
| `field_sample` | One integer x,y,z source sample |
| `sample_triangle` | Scalar value from a shared pick's triangle and barycentric weights |
| `set_slice` | Replace the active axis and fractional index |
| `set_transfer` | Replace range and optionally the linear RGB stops |

Mutations require `scientific.edit`, an expected provider revision and an
idempotency key. They use `ScientificSliceView` commands. Invalid replacements
leave the scene intact. Removing or editing its mesh externally makes the view
stale; disposing the view removes its registry entry and owned mesh. This
checkpoint does not provide undo or temporal datasets.

Connect the shared viewport provider's object metadata to `provider.metadata`.
Then pass its pick's runtime object ID, scene revision, triangle index and
barycentric weights to `sample_triangle`. That join checks source geometry and
identity. It does not prove pixel visibility. For direct Dart picks,
`view.inspectHit` accepts the actual `PickResult` and rejects older snapshots.
The host retains document, viewport, camera and frame correlation. Static fields
report time as unavailable. Imported source descriptions remain untrusted data.

## Run the native examples and checks

Use this workspace's Flutter 3.47.5 SDK, which supplies a compatible Dart SDK.
Run dependency resolution from the workspace root, under the shared lock when
other workstreams are active. Run the following from this package directory so
Dart loads the native build hook:

```sh
dart run example/synthetic_slice.dart /tmp/zyren-scientific-evidence
RUN_NATIVE_GPU=1 dart test --reporter expanded
dart analyze
python3 example/verify_mcp.py /path/to/flutter/bin/dart /tmp/zyren-scientific-evidence/mcp
```

The first example writes a native PNG and JSON with synthetic provenance, unit
labels, numerical error and backend identity. The PNG also has a synthetic-data
text chunk. Its missing center column produces a visible hole.

The MCP check starts `example/agent_host.dart`, which reuses the shared devtools
stdio server. It discovers tools, picks the captured scene, joins the scalar
value, checks read-only denial, changes the slice through a granted command,
verifies changed native pixels and tests retry/stale behavior. EOF closes the
host and backend. This example explicitly grants scientific editing; your own
host must choose its policy. No network listener starts.

On 2026-10-02, 18 tests and the live stdio MCP check passed on Apple M3 Max/Metal.
The native transfer fixture had a maximum sampled channel error of 0/255. The
MCP scalar join differed from its analytic value by `2.69e-8 K`. These are
synthetic fixture results using offscreen readback. Flutter presentation,
human pointer interaction, Vulkan and DX12 remain unverified here.

Isosurfaces, unstructured surfaces, vector fields, streamlines, time-varying
results and GPU volume rendering remain in [the workstream plan](../../plans/zyren-plugins/scientific.md).
This package has not been published.
