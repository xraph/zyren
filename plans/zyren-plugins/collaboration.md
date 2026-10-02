# Collaboration

You can follow the scene collaboration work here. This chat owns
`packages/zyren_collaboration` and its examples. Work stays on `main` and uses
`/tmp/zyren-plugin-expansion.lock` for shared edits, dependency resolution and
Git operations.

## Source audit

The engineering review protocol already covers these workflows:

- `lib/src/document.dart` stores source object IDs and anchored review notes.
- `lib/src/merge.dart` provides whole-record three-way merges. A conflict choice
  applies only to the exact base, local and remote values you reviewed.
- `EngineeringSessionStore.compareAndWrite` rejects stale revision tokens.
- `FileEngineeringSessionStore` queues writes, locks across processes and
  replaces the saved envelope atomically. `FileEngineeringStore` alone does
  not coordinate shared writers.
- `HttpEngineeringSessionStore` sends conditional writes with strong ETags.
  `EngineeringReviewServer` enforces host authorization, bounds bodies and
  supports HTTPS. Existing engineering tests cover these services.
- `EngineeringImport` and its sidecars bind source IDs after import. Display
  names and `Object3D.id` cannot serve as persistent IDs.

The core exports immutable `Vec3` and `Quat`, `Object3D` transform/visibility
setters, `ScenePlugin`, attachment scopes and frame invalidation. Collaboration
can use those APIs without changing the renderer or importing engineering into
the general-purpose core.

## Decisions

The first slice edits transforms and visibility on an existing object set.
You supply stable `(source, key)` IDs and a scene session epoch. The epoch must
change whenever you discard the operation history or replace the source model.
Each operation carries schema version 1, scene identity, epoch, operation ID,
target ID and the field revision observed when you prepared the edit.

One authority serializes accepted operations. Revisions are tracked per field,
so independent edits survive concurrent submission. Conflicting edits return
the proposed operation and current state. Keeping a local edit creates a new
operation against the exact reported field revision; another intervening edit
must conflict again. We do not silently pick a winner.

The host supplies read and write permission callbacks and binds authenticated
principals to transports. Credentials never enter the scene document. A bounded
receipt table remembers accepted operation IDs for retries after lost replies.
It rejects new operations when full; dropping old receipts would allow a retry
to execute twice. Durable receipt retention belongs to the persistence phase.

Engineering review documents keep their existing merge and storage protocol.
Scene operations do not encode annotations or replace that HTTP service. A
future host can run both services with the same source identity mapping and
authorization provider. Collaborative editing does not own physics ticks,
prediction, rollback or authoritative multiplayer simulation.

## Phases and acceptance

1. Implement versioned scene operations and the local authority. Check stable
   identity, strict finite transforms, bounded codecs, independent edits,
   same-field conflicts, exact retry identity, read/write denial, revoked
   permissions, async races and full receipt capacity.
2. Add a client with retained pending operations after transport failure and a
   scene plugin that applies acknowledged snapshots. Run two clients with real
   Zyren scene graphs. Check lost replies, retry, explicit conflict resolution,
   stale replies, reload binding and detach during an in-flight request.
3. Add durable snapshots and operation receipts through a transactional host
   store. Validate restart recovery, multi-process conditional writes, schema
   migration, history retention and crash boundaries. Reuse engineering review
   storage for review data. Do not create a second review protocol.
4. Add HTTPS and WebSocket transport adapters with host-owned credentials,
   reconnect, deadlines, payload limits and backpressure. Verify two processes,
   TLS, denied access, interrupted replies and retry against the durable store.
5. Add presence and shared cameras as expiring session data. Check disconnect
   expiry, sequence ordering, rate limits and opt-in camera following. Camera
   updates must not produce persistent object-edit revisions.
6. Add durable offline queues and reconciliation. Pin the scene epoch and
   source versions, surface deleted or remapped objects, retain rejected edits
   for inspection and require fresh decisions when conflicts change.
7. Extend scene edits to creation, deletion, reparenting and material changes
   after Studio and pipeline contracts exist. Add resource ownership checks,
   undo as conditional inverse operations and permissions per action. Verify
   desktop and narrow native UI before claiming a complete shared editor.

## Required runtime agent access

Agent integration is part of completion. Follow `agent-runtime.md` and the
interaction owner's versioned `zyren_agents` contract. This package will expose
scene and field revisions, pending edits and conflicts, paginated accepted
operation history, presence coverage and host-permitted actions. Presence must
report unavailable until an actual presence service exists.

The optional engineering provider will call the existing review APIs for object
records, notes, isolation and shared synchronization. It must preserve host
property filtering, authorization and exact engineering version checks. It will
not create another review server or copy the merge implementation.

The current shared registry is not yet available. Build typed domain queries
and actions now, then add registration, input/output schemas, cancellation,
stale-target and disposal checks against its actual API. Discovery through a
private helper does not count as shared agent support. Correlate source IDs with
runtime objects through explicit bindings; the shared viewport provider owns
camera, logical-coordinate, pixel-ratio and presented-frame evidence. This
package makes no rendered-pixel claims.

Acceptance requires actual discovery and calls through the common registry,
authorized edits and undo through normal commands, explicit denial and stale
results, bounded history, target cleanup, and optional engineering coverage.
Native point-to-object and live MCP checks remain separate from CPU tests.

## Dependencies and shared changes

The first slice depends only on `zyren` and the existing `test` dependency.
It does not depend on unfinished pipeline, Studio or interaction APIs.

Requested shared edits: add `packages/zyren_collaboration` to root
`pubspec.yaml`, refresh dependency resolution, and add the package's public
import allowlist to `tool/check_package_boundaries.dart`. These are additive
workspace registration changes with no public API impact. Check other plans
and current file contents while holding the lock before applying them.

No core, native, Flutter or engineering API change is required.

## Current evidence

The first scene-operation slice is implemented: schema-1 payloads, stable IDs,
field revisions, serialized host permissions, exact retry receipts, paginated
history, retained pending edits, explicit conflicts and acknowledged scene
bindings. The local example runs two scene graphs with a lost reply and conflict.

The collaboration test file passed 18 tests on 2026-10-02. Package analysis reported no issues. The package boundary check passed. The
local example reported a duplicate retry at revision 1, a conflict, and both
scene graphs at x=2 and revision 2.
The shared agent contract has now been published in source; provider work follows
this first checkpoint. No native presentation, device, network, persistence or offline
reconciliation check has run for this package. The package is not published.

Commits: pending the first checked implementation checkpoint.
