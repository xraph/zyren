# Zyren agents

You can expose a running plugin through a typed provider, inspect a named viewport
and invoke commands within scopes granted by your host. The package uses public
Dart core APIs. It starts no server and runs no model in the render loop.

```dart
final registry = AgentRegistry(grantedScopes: {'tools.transform'});
final registration = registry.register(provider);
final page = registry.discover(limit: 32);
final result = await registry.call(
  providerId: provider.id,
  instanceId: provider.instanceId,
  tool: 'inspect',
  arguments: {},
  expectedRevision: provider.revision,
);
registration.dispose();
registry.dispose();
```

Implement `AgentProvider` with `id`, `version`, `instanceId`, `revision`, `tools`
and `invoke`. You can extend it to inherit empty capabilities and resources.
`AgentTool` declares schemas for arguments and the result's `data`, read/write
classification, required scopes, a result byte limit and example arguments.
IDs allow letters, digits, dots, underscores and hyphens, up to 96 characters.

Use `AgentConformance.checkRead` in your tests to call a registered provider and
check its read result and revision. Add domain assertions, mutation checks and
lifecycle tests. The harness does not establish native or screen correctness.

## Schemas and outcomes

Schema version is `1.0`. `AgentSchema` supports object, array, string, number,
integer, boolean and null types; properties, required, additionalProperties,
items, min/maxItems, minimum/maximum, exclusiveMinimum/exclusiveMaximum, min/maxLength, enum, title and description.
Unsupported keywords fail when you construct a tool. Schemas and results contain
JSON-compatible values and are copied into immutable data.

Calls distinguish `ok`, `empty`, `unsupported`, `unavailable`, `denied`, `stale`,
`cancelled`, `failed` and `invalid`. Discovery is paginated. Input defaults to
64 KiB; tools default to 64 KiB results and can explicitly request up to 1 MiB.
Providers support at most 128 tools and 32 simultaneous calls per instance.

Mutations require host-granted scopes, `expectedRevision` and `idempotencyKey`.
Return the resulting revision and affected IDs after using your normal domain
commands. The registry rejects concurrent distinct mutations on one provider.
Identical retries share the same result, including while the first call runs;
reusing a key with different arguments fails. The retry ledger holds 256 calls
per registry session by default. A full ledger rejects new mutations and keeps
prior records. Unregistering retires its command keys; reattaching the same
instance cannot run those commands again. Retired keys return stale so you can
refresh state. Persistence across host process restarts belongs to your domain
command store; this in-memory registry does not claim that guarantee.

Long jobs check `context.checkCancelled()` before committing and between bounded
work units. Use `context.reportProgress(fraction, message)` for progress. The
registry cancels pending calls when you unregister. Cancellation is cooperative;
it cannot roll back a command that already committed. Check expected revisions
again before an asynchronous mutation commits. Avoid returning private exception
messages through tool results.

## Viewport evidence

`AgentViewportProvider` exposes `context`, `pick` and `inspect_object` for one
explicit viewport instance. Supply scene/document identities, current camera and
logical metrics getters, and optional host-approved metadata, presentation and UI
state. The host reports active view, focus, selection, overlays, render dimensions,
loading and capture capabilities in `hostState`; missing values remain unknown.
Use separate provider instances for separate viewports.

Pick coordinates default to local logical pixels with a top-left origin. You can
set `coordinateSpace` to `normalized` (0..1), `window` (logical pixels) or `image`
(image pixels). Window points need the host's `windowOrigin`; image points need
an `AgentImageMapping`, an `imageId` and matching presented-frame evidence. The
mapping describes the content rectangle inside a letterboxed image. Results
retain both the input point and the conversion metadata. Resizing or changing the
camera makes an older image mapping stale.
The query reports runtime IDs separately from optional source IDs, world and
object-local geometry, instance/triangle identity, barycentrics, UVs, provenance
and action references. Multi-hits include triangle intersections, so one mesh can
appear more than once. Results follow distance, traversal, instance and triangle
order and report truncation.

CPU triangle hits do not establish rendered pixel visibility. The coverage record
names texture alpha, transparency, custom displacement, line/point footprints,
Flutter overlay interception and unloaded content as unknown. A known frame only
matches current geometry when scene/camera revisions, camera identity, logical
extent and DPR match. `expectedFrameId` rejects unknown or stale correlation.
Native image capture and GPU visibility queries remain separate capabilities.

Source labels and enrichment are untrusted scene data. Supply only properties the
host permits; metadata is bounded to 8 KiB per object. Runtime IDs last within the
Dart isolate and must not be saved as persistent source identity.


Object inspection and rich hits include projected world bounds for meshes,
including built-in deformation and instances. They identify layer and section
clipping decisions. Bounds crossing the depth clip plane return unavailable, and
projected bounds never establish rendered pixel visibility.

## Optional long operations

The existing devtools bridge exposes `agent_job_start`, `agent_job_status`,
`agent_job_cancel` and `agent_job_release` through its authenticated endpoint and
MCP tools list. Start with a unique `jobId`, provider/instance/tool and `readOnly`.
Mutations also need the normal expected revision, key and host scopes. Poll the
job for its latest progress and result; release completed jobs when you're done.
The bridge retains at most 16 jobs, requests cancellation after five minutes and
cancels all jobs on close. A cancellation request does not imply rollback or
completion before the provider acknowledges it.

`agent_changes` reads up to 64 events after a cursor from a 128-event buffer.
Refresh discovery and state when `gap` is true. This is an explicit polling feed,
not an MCP resource subscription. Direct callers can subscribe to registry changes.
