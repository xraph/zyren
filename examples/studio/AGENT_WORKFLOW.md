# Studio agent workflow

Open `lib/main.dart` for the working native editor. The Agent tab uses a real
model connection and the same domain commands as the editor. The separate
layout mock remains available at `lib/mock/main.dart`.

## Runtime path

```text
Your prompt + active scene context
  -> configured model endpoint
  -> list_plugins / describe_plugin
  -> call_tool
  -> schema and host-scope checks
  -> review mutation arguments
  -> registration and revision check
  -> plugin command and normal history
  -> actual tool result back to the model
```

Chat knows the registry contract, not a hardcoded set of plugin names. Discovery
is paginated, and a provider added after the conversation starts appears on the
next discovery call. The model sees unavailable, denied, stale, cancelled and
failed results separately. A successful transport response does not turn a
failed plugin operation into success.

The run is bounded to 24 model steps and 96 calls. Conversation context is bounded
to 512 KiB. You can stop a request or pending review. A provider already executing
must cooperate with cancellation. Completed changes are retained in the normal
scene history. Conversation history stays in memory and resets on document reload.
Replies arrive per model step; token streaming is not implemented.

## What the default Studio host binds

| Domain | Binding | Verification in this change |
| --- | --- | --- |
| Scene selection, transforms, undo and redo | `StudioAgentProvider` | Existing registry and editor tests |
| Materials, prefabs, visibility, authored clips | `StudioAuthoringAgentProvider` | Existing authoring tests |
| Asset pins and diagnostics | `StudioAssetsAgentProvider` | Existing real GLB import test |
| Primitive modeling and character blockouts | `StudioModelingAgentProvider` | Round-trip, atomicity, undo/redo and native character creation |
| Persistence | `StudioPersistenceAgentProvider` | Native reviewed save and reload |
| Camera timeline | `TimelineAgentProvider` | Existing provider tests |
| Engineering review | `EngineeringReviewAgentProvider` | Existing read-only policy remains; annotation edits denied |
| Viewport evidence | `AgentViewportProvider` | Existing viewport tests; pixel visibility remains unknown |
| GPU diagnostics | `DiagnosticsAgentProvider` | Existing provider tests; unsupported registration appears in context gaps |
| Collaboration | Registered while a session is attached | Existing host tests; no new live remote-room qualification |

## Other plugin adapters

The repository already contains adapters for the following domains. The shared
chat bridge can use them once the host supplies a real runtime instance and
registers its provider. The default Studio document does not instantiate them.
They are **not live-qualified Studio integrations** in this change.

| Domain | Host binding still needed |
| --- | --- |
| Characters and locomotion | Imported clips, rig/motor, pose ownership and command/history gateway |
| glTF animation | Imported model instance and animation timeline |
| Physics | Attached physics world, bodies and native simulation ownership |
| Particles | Active emitters and particle controller |
| Audio | Audio engine, loaded sources and playback ownership |
| Configurator | Product configuration, choices and active instance |
| Interaction | Interaction controller and active targets |
| Navigation | Navigation runtime/world, agents and loaded navigation data |
| Capture, effects and video | Capture session, output destination and runtime effect/video resources |
| Scientific fields | Loaded field or dataset and live view controller |
| Point clouds and splats | Loaded/streaming dataset, source identity and resource budget |
| Geospatial reality context | Registered cloud/splat context and source mappings |
| Pipeline build/ingest | Pipeline service, asset sources, cache and build configuration |
| XR | Native XR session, permission and device capabilities |

Core renderer, geospatial and tool packages without their own agent adapter are
not made agent-controllable merely by being present in the workspace. Add a
typed provider for the intended public operations; do not expose arbitrary code
execution as a substitute.

## Adding a plugin, including future morphing

A Studio host passes `StudioAgentExtension` entries to `StudioEditor.agentExtensions`.
Each entry declares host-granted scopes and an attach callback. The callback can
attach runtime plugins with `context.usePlugin`, register providers with
`context.register`, and retain cleanup registrations with `context.keep`.
It receives the active `StudioScene`, availability check and change notification.
Use public APIs and bind to authored IDs. Do not keep object references across a
structural reconstruction without re-resolving them.

For engine-owned lifetimes, attach `AgentRegistryPlugin` and an
`AgentProviderPlugin` that depends on the runtime plugin. The engine publishes
`sceneAgents`; the adapter registers its providers in the attachment scope.
Detachment and recovery retire the old registrations automatically.

A morphing plugin should expose inspection, target creation, weight editing and
baking as typed tools. It must own topology validation, target identity, undo,
saved state and native deformation updates. The bridge already accepts new tool
schemas and plugin IDs. Tests verify discovery after registration and rejection
of an approval for a retired provider, but no morphing runtime is installed.

## Configuration and data

OpenAI-compatible Chat Completions, Anthropic Messages and local compatible
servers have native HTTP adapters. Configure a base URL including its version
path. Model IDs are user-supplied. No model list is hardcoded.

The selected endpoint receives your prompts, selected-object/document context
and requested tool results. Scene labels and imported data are treated as
untrusted input. The profile file stores protocol, URL and model only. API keys
remain in memory and are never serialized to the scene or profile. OS credential
storage and persistent chat history remain future work.

## Checks

From the workspace root:

```sh
fvm dart test packages/zyren_agents/test packages/zyren_studio/test
fvm flutter test --no-pub examples/studio/test
fvm dart tool/check_package_boundaries.dart
```

The core suite passed 51 tests before the additional engine lifecycle test; that
lifecycle test also passed. All 11 Studio tests passed, including configuration,
review and actual modeling calls at 1280, 396 and 328 logical pixels. The macOS
debug build and package-boundary checks passed.

A native macOS Metal session used an explicitly labeled local protocol fixture
to discover providers across two pages, inspect modeling tools, review character
creation, execute it, review save, save and reload the character. This verifies
the HTTP/tool/editor path. It does not qualify a live LLM's planning quality.
OpenAI-compatible, local and Anthropic adapters were checked against loopback
HTTP fixtures. No paid provider credentials were used. Other native platforms
and the unbound plugin domains above remain unverified for this chat workflow.
