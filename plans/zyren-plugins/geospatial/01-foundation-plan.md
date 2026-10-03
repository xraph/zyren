# Geospatial foundation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. Execute sequentially in this chat, as selected on 2026-10-03.

**Goal:** Install independently owned geospatial extensions and manage real layers through a headless public API.

**Architecture:** Expand geospatial extensions into ordinary ScenePlugin instances. Keep world services, layer state and domain registration in geospatial, with only a generic composition-validation hook in core. Migrate existing terrain, atmosphere and camera integrations without replacing their renderers.

**Tech Stack:** Dart, Flutter 3.47.5 through FVM, existing SceneEngine and native Metal/Vulkan/DX12 backends.

**Spec:** [Approved platform design](design.md), especially composition, layers, time and migration.

## Global constraints

- Rendering remains native Metal, Vulkan or DX12.
- The core stays independent of geospatial, Flutter, provider APIs and simulation domains.
- Only one geospatial host is allowed per scene in the initial contract.
- Hidden does not mean unloaded, and rendering disabled does not imply simulation paused.
- Stay on the active branch. Preserve concurrent changes and make focused local commits, with no co-author trailers, pushes or merges.
- Read `rex-voice`, then apply `humanizer` in embedded mode to shipped prose.
- Run Dart with `.fvm/flutter_sdk/bin/dart` from the repository root. From a package directory use `../../.fvm/flutter_sdk/bin/dart`.

## Review focus

- A configured host installed without expansion must fail before allocating a backend: task F1.
- Failed attachment must remove only owned registrations and accurately report survivors: F1 and F2.
- Group cycles and stale edits must leave the previous layer snapshot intact: F2.
- Two terrain instances and multiple views must not share mutable source or camera state: F3 and F4.
- A visual update must not advance a simulation clock or change data provenance: F4 and F5.

## Delivery boundary

This plan delivers the host and built-in layer machinery. Persistent data is
[plan 02](02-offline-plan.md); professional water is [plan 03](03-ocean-plan.md).
Navigation, flight and orbital solvers remain separately scoped programme work
in the platform design. Completing this plan does not mark those capabilities done.

## File ownership

Create focused geospatial files under `lib/src/extensions/`, `lib/src/layers/` and
`lib/src/world/`. Keep public exports in the existing `zyren_geospatial.dart`.
Tests live alongside existing package tests. Touch core plugin validation only
where F1 requires it. Do not edit the native renderer in this plan.

## Task 1: F1 Extension composition and independent lifecycle

Files:

- Modify `packages/zyren/lib/src/plugins/engine.dart` and `plugin_updates.dart`.
- Modify `packages/zyren_geospatial/lib/src/geospatial_plugin.dart` and its exports.
- Create `packages/zyren_geospatial/lib/src/extensions/extension.dart`,
  `context.dart`, `registry.dart` and `composition.dart`.
- Test `packages/zyren/test/plugin_composition_test.dart` and
  `packages/zyren_geospatial/test/extensions/composition_test.dart`.

Interfaces:

```dart
// Add to ScenePlugin. The engine passes an immutable, resolved list before
// backend creation or live detach. The default implementation does nothing.
void validateComposition(List<ScenePlugin> plugins) {}

// GeospatialExtension extends ScenePlugin and gets its own core context.
// Its full ID is 'geospatial.ext.$localId'; local IDs reject '.' and '/'.
String get localId;
int get contractVersion; // Initially 1.
FutureOr<void> attachGeospatial(GeospatialContext context);
FutureOr<void> beforeGeospatialRender(GeospatialContext context, FrameInfo frame);
FutureOr<void> detachGeospatial(GeospatialContext context);

// GeospatialPlugin additions. Keep the existing ellipsoid parameter.
GeospatialPlugin({Ellipsoid ellipsoid = Ellipsoid.wgs84,
  List<GeospatialExtension> extensions = const []});
List<ScenePlugin> get scenePlugins;
GeoExtensionRegistry get registry;

// GeospatialContext exposes the actual adapter-owned PluginContext and host.
PluginContext get sceneContext;
GeospatialReference get reference;
GeoExtensionRegistry get registry;
```

Only `attachGeospatial` is required; the before-render and detach hooks default
to no-ops. The base extension obtains its host from the shared geospatial runtime
service and wraps its own core context. It never manually invokes another
extension's lifecycle.

`GeoExtensionRegistry.snapshot` returns immutable records of full ID, contract
version, lifecycle state and failure. Required dependencies use core plugin IDs.
Typed optional services use `GeoServiceKey<T>(name, version)`, owned registration
tokens, `provide<T>(key, value)` and nullable `find<T>(key)`. Duplicate providers
fail. Scope disposal withdraws a provider and emits one capability-change event.

- [x] Add this regression to the existing geospatial plugin tests:

```dart
test('an unexpanded configured host never allocates a renderer', () async {
  var allocated = false;
  final geo = GeospatialPlugin(extensions: [_EmptyExtension()]);
  await expectLater(SceneEngine.create(
    scene: Scene(), camera: PerspectiveCamera(), plugins: [geo],
    rendererFactory: () async {
      allocated = true;
      throw StateError('renderer must not be created');
    },
  ), throwsStateError);
  expect(allocated, isFalse);
});

class _EmptyExtension extends GeospatialExtension {
  @override String get localId => 'empty';
  @override int get contractVersion => 1;
  @override void attachGeospatial(GeospatialContext context) {}
}
```

- [x] Run `dart test test/extensions/composition_test.dart` with the package SDK
  path above and record the missing-API failure. Add actual lifecycle probes using
  the existing `plugin_test.dart` renderer fixture: duplicate IDs, dependency
  cycles, attachment cancellation, optional service loss and reverse cleanup.
- [x] Resolve core IDs first, call each composition validator on that same
  immutable list, then create the backend or begin live reconciliation. The
  geospatial validator checks object identity as well as ID, expected adapters,
  contract versions and one host. Cache expansion once; never recreate extension
  objects in the getter. Context construction follows this ownership rule:

```dart
final scoped = GeospatialContext(sceneContext: context, host: host);
final token = host.registry.beginAttach(id, contractVersion);
context.scope.keep(token);
await attachGeospatial(scoped);
host.registry.markAttached(id);
```

  Define the shown constructor and `beginAttach(String, int) -> Registration` /
  `markAttached(String) -> void` methods in the named context/registry files.
  The registration removes its own generation only; a late old detach cannot
  remove a replacement. Preserve core's failed-update survivor reporting.
- [x] Run new core/plugin tests, geospatial `plugin_test.dart` and analyzer.
  Verify direct legacy construction still passes. Run the package boundary check.
- [x] Review exact paths and commit `feat(geospatial): add scoped extension composition`.

## Task 2: F2 Layer transactions, capabilities and persistence

Files:

- Create `lib/src/layers/layer.dart`, `controller.dart`, `change.dart`,
  `codec.dart` and `selection.dart` inside `packages/zyren_geospatial`.
- Export them and add `GeospatialPlugin.layers` / `GeospatialContext.layers`.
- Test `test/layers/controller_test.dart`, `codec_test.dart` and `selection_test.dart`.

Interfaces:

```dart
GeoLayer({required String id, required String owner, required String kind,
  String? parentId, bool visible = true, bool queryable = true,
  double opacity = 1, Set<GeoLayerCapability> capabilities = const {}});
enum GeoLayerCapability { opacity, reorder, query, refresh, offline }
GeoLayerController();
int get revision;
List<GeoLayer> get snapshot;
void transact(int expectedRevision, void Function(GeoLayerEdit) edit);
bool effectiveVisible(String id);
double effectiveOpacity(String id);
// GeoLayerEdit operations:
void add(GeoLayer layer);
void remove(String id, {bool descendants = false});
void reparent(String id, String? parentId);
void move(String id, int siblingIndex);
void setVisible(String id, bool visible);
void setOpacity(String id, double opacity);
```

The controller also exposes `setVisible(String id, bool value)` as a one-edit
transaction using its current revision, matching the platform's usage example.
The transaction API remains available for callers that must reject stale edits.

Add `GeoLayerStatus` with separate lifecycle/data state, optional coverage, source
and style revisions, attribution and a structured failure. `GeoLayerCodec`
registers `kind`, `schemaVersion`, configuration encoder/decoder and migrations;
`encode() -> Map<String,Object?>` / `decode(Map<String,Object?>)` operate on the
whole controller document. `GeoFeatureHit` carries layer ID, feature ID, geodetic
position, source revision and opaque host metadata. Selection stores stable IDs,
never mesh handles, and drops removed references in the same transaction.

- [x] Write and run the failing transaction test:

```dart
test('cycles leave layer state and revision unchanged', () {
  final layers = GeoLayerController();
  layers.transact(0, (edit) {
    edit.add(GeoLayer(id: 'a', owner: 'test', kind: 'group'));
    edit.add(GeoLayer(id: 'b', owner: 'test', kind: 'group', parentId: 'a'));
  });
  expect(() => layers.transact(1, (e) => e.reparent('a', 'b')),
    throwsArgumentError);
  expect(layers.revision, 1);
  expect(layers.snapshot.first.parentId, isNull);
});
```

- [x] Clone into a candidate, validate IDs/parents/capabilities/finite values,
  resolve effective state, then publish once. Use ancestor multiplication for
  opacity and ancestor conjunction for visibility. Reject stale revisions.

```dart
final candidate = List<GeoLayer>.of(snapshot);
final edit = GeoLayerEdit(candidate);
operation(edit);
edit.validate();
publish(List.unmodifiable(candidate), revision + 1);
```

  `GeoLayerEdit(List<GeoLayer>)`, `validate()` and internal `publish(...)` are
  implementation members of the named files, not additional public entry points.
  Tests also cover invalid sibling moves, inherited hidden state, unsupported
  opacity, mixed success/failure batches and disposal during notification.
- [x] Implement codec versioning and reject nonfinite/oversized documents before
  publication. Unknown plugin configurations remain unresolved with their original
  configuration retained. Round-trip IDs, ordering, source versions and policies;
  explicitly reject embedded credentials and live objects.
- [x] Run all layer tests and analyzer. Verify selection invalidation, bounds
  across the antimeridian and explicit unavailable versus empty states.
- [x] Update package usage documentation and commit `feat(geospatial): manage layers through atomic transactions`.

## Task 3: F3 Connect layers to existing terrain, imagery and atmosphere

Files:

- Modify `lib/src/terrain/terrain_plugin.dart`, `imagery_terrain_source.dart`,
  `overlay_terrain_source.dart` and `globe_controls_plugin.dart` only as needed.
- Create `lib/src/extensions/terrain_extension.dart`, `atmosphere_extension.dart`
  and `camera_extension.dart`.
- Test `test/layers/terrain_integration_test.dart` and `native_layer_test.dart`.

Interfaces: `TerrainExtension({required String id, required TerrainSource source})`
owns one terrain adapter and its layer. `AtmosphereExtension` wraps one existing
`AtmospherePlugin`. `GlobeCameraExtension` connects one existing globe control rig.
Add an optional instance ID to terrain with its old ID as the default. The wrapper
must preserve each plugin's actual context, source and resource ownership.

- [x] Write a two-terrain fixture using two `ProceduralTerrainSource` instances
  and the existing terrain test setup. Check distinct IDs/groups, source errors
  confined to one layer, visible attribution and pick-to-layer mapping.
- [x] Drive the same objects from layer changes:

```dart
final revision = geospatial.layers.revision;
geospatial.layers.transact(revision, (edit) {
  edit.setVisible('coast', false);
  edit.move('survey', 0);
});
```

  The fixture defines `geospatial` with terrain IDs `coast` and `survey`.
  Assert the coast group stops rendering and picking according to policy while
  its cached content and simulation service remain independently retained.
- [x] Add an explicit imagery-stack revision setter on the adapter. Recompose
  imagery through the existing worker and cancel obsolete generations. Opacity
  changes cannot mutate immutable source data in place. Preserve parent coverage
  until new child content is ready and preserve the previous material on failure.
- [x] Run terrain/imagery/overlay suites and one native layer fixture at two
  viewport sizes. Check detach leaves no owned scene objects or native resources.
- [x] Document standalone compatibility and commit `feat(geospatial): connect terrain and atmosphere layers`.

## Task 4: F4 World frames and single-owner simulation time

Files:

- Create `lib/src/world/reference.dart`, `time.dart`, `simulation.dart` and
  `sample.dart` in geospatial.
- Create `lib/src/world/external_clock.dart` for externally supplied ticks. Put
  game-session wiring in the application, keeping both packages independent.
- Test `packages/zyren_geospatial/test/world/frame_test.dart`, `time_test.dart`.

Interfaces:

```dart
GeoInstant({required int tick, required int hz, required DateTime epoch});
GeoSimulationClock({int hz = 60, int maxCatchUpSteps = 8});
int get tick;
GeoInstant get instant;
bool get paused;
set paused(bool value);
int advance(Duration elapsed); // Returns admitted steps, with dropped-time stats.
void step(); // One explicit tick; reject a competing driver lease.
GeoWorldFrame({required GeospatialReference reference, required Geodetic origin});
Vec3 toLocal(Vec3 ecef);
Vec3 toEcef(Vec3 local);
```

`GeoSample<T>` contains availability, nullable value, reference/time/source
revisions and optional age/error estimates. A success requires a value and valid
provenance. `GeoSimulationSystem` declares ID/dependencies and
`FutureOr<void> step(GeoInstant instant)`. One driver owns a leased system graph.
`GeoExternalClock.accept(GeoInstant instant)` publishes the host's validated tick
without admitting wall time. The application supplies its game tick through this
adapter; it never calls a second clock. Accepting an older tick requires an explicit
new replay generation, and duplicate ticks cannot step a system twice.

- [x] Write the render-independence regression with the current game and physics
  fixtures. Add the pure-clock case:

```dart
test('pause does not turn wall time into a jump on resume', () {
  final clock = GeoSimulationClock(hz: 60);
  clock.paused = true;
  expect(clock.advance(const Duration(hours: 1)), 0);
  expect(clock.tick, 0);
  clock.paused = false;
  expect(clock.advance(const Duration(microseconds: 16667)), 1);
});
```

- [x] Use integer tick identity and a bounded admission accumulator. Validate
  epoch/time scale, positive rate, finite transforms and rebase revisions. Emit
  the old-to-new rigid transform before any consumer publishes a new frame.
- [x] Transform position with translation/rotation; transform velocity and forces
  with rotation only. Tests compare round-trips at the equator, poles and dateline.
  Provider height-datum conversion must be explicit and can return unavailable.
- [x] Test dependency ordering, duplicate drivers, failed steps, replay generation,
  stale sample rejection and camera-only changes. Never implement rewind with
  negative delta. Include an application fixture driven by the existing game session.
- [x] Commit `feat(geospatial): share world frames and simulation time`.

## Task 5: F5 Camera ownership, styles and public integration example

Files:

- Create `lib/src/extensions/camera_controller.dart` and `visual_registry.dart`.
- Modify `examples/planet/lib/main.dart` only after checking its current ownership
  and route structure. Put new fixtures under `examples/planet/lib/layers/`.
- Add geospatial tests `camera_controller_test.dart`, `visual_registry_test.dart`
  and a Flutter integration test in the example's existing test directory.
- Update `packages/zyren_geospatial/README.md` and this directory's progress table.

Interfaces: `GeoCameraController.activate(String rigId)`,
`registerRig(String id, ScenePlugin rig) -> Registration` and
`registerModifier(String id, int priority, GeospatialCameraPose Function(GeospatialCameraPose) modify) -> Registration`.
`GeoVisualRegistry` registers versioned styles and named pass dependencies against
the existing graph; `validate()` rejects cycles and conflicting exclusive owners.

- [ ] Test a deterministic pose chain with two modifiers, reversed registration
  order and one active rig. Equal priorities resolve by stable ID, not callback
  arrival. Detach removes only its registration.
- [ ] Define the composition explicitly:

```dart
var pose = activeRig.pose;
for (final modifier in orderedModifiers) {
  pose = modifier.apply(pose);
}
pose.applyTo(camera);
```

  `activeRig.pose`, `orderedModifiers` and the target `camera` are controller
  internals. Modifiers cannot install their own frame loops. Picking/collision
  constraints run before the final pose publication, using existing controls.
- [ ] Build a native Planet example with two layers, atmosphere, a camera switch,
  source failure/retry and persisted layer configuration. Put controls in the
  application and keep geospatial free of widgets. Reuse the current theme and
  compact controls; do not create a sidebar dependency.
- [ ] Run package tests/analyzer/boundary checks and the example on desktop and
  a narrow native viewport. Record screen evidence and unresolved device checks.
- [ ] Commit `feat(geospatial): expose camera and visual extension services`.

## Completion review

Every F task ends with its targeted red/green evidence and focused commit. Before
starting plan 02, run the full affected geospatial tests and the core plugin tests
once, then record active APIs and any drift from the written interfaces. Inspect
the current branch and staged scope before each commit. No task authorizes pushing.
