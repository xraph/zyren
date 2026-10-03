# Teams, shared policies and diagnostics

Create a `GameTeam` for one episode and entity table. Join live
`BrainIdentity` values and leave when an actor despawns or changes teams. A join
change advances that member's epoch. Old generations and old memberships cannot
receive queued messages. Each team admits at most 64 members and 4096 membership
changes; start a new team for the next episode.

The host owns `TeamChannel`. Supply a trusted service-side `SensorSnapshot` with
`capture`, then permitted `ObservationFrame` values with `observe`. `send` takes
a target handle, not a target position. The channel derives the historical local
position from a visible observation, checks the sender/recipient team and
snapshot range, then delays delivery according to `CommunicationProfile`.
Unknown observations cannot supply a target. Hidden target movement or removal
does not update an already captured position.

`receive(actor, tick: tick)` consumes due messages once. `deliverTo(memory,
tick: tick)` applies the same bounded records through the existing A4 team belief
contract. Messages pin sender/recipient generations, membership epochs, schema,
sensor profile, observation tick and expiry. The position retains its sender
frame. If you transform it for navigation, use the observer transform captured
at that observation tick, never the sender's current moving pose.

A channel retains up to eight teams, 64 compact observer records, 256 queued
messages and 4096 event IDs. It retains visible entity records rather than camera
image tensors. Exhausted event ledgers reject new sends instead of forgetting
duplicate protection. `clear` discards observations and pending delivery but
keeps event tombstones. Construct a new channel for a new episode or rewind.

## Shared native models

`PolicyGroup(episodeId: ..., entities: ..., ml: ...)` uses your existing
`MlScheduler` and model cache. Join an identity and `PolicyContract`, obtain its
brain with `brainFor`, and await `leave` during removal. Actors with the same
weights must share the exact immutable model manifest; their policy contracts
can retain separate schema and encoder pins. Each actor owns its `PolicyState`,
memory and unresolved request.

Call `record(context)` when your host publishes a current brain context for
goal diagnostics. `modelCount` counts active model pins; the ML cache's resident
count reports actual native sessions. The group caps 64 actors and 32 MiB of
recurrent state. `close` drains actor work but leaves the shared scheduler open
for its owner to close.

`creditTeamReward` accepts a host-authored event ID and bounded reward. It credits
only current matching team identities. Opponents and later replacement
generations receive no earlier credit. Duplicate reward events cannot apply
twice. This is a runtime reward contract, not a trained multi-agent result. T6
adds the training adapter and acceptance evidence.

## Optional developer tools

Import `agents.dart` only in tooling hosts. Construct `GameAiPolicyHost` with a
bounded registered model map, an authoritative `currentRevision` callback and
your gameplay `permits` validator. Include session lifecycle changes in that
revision, rather than only the policy group's membership revision. The host
rechecks revision, actor generation and control after native model preparation
and before swapping. Cancelled preparation leaves the active brain unchanged.

Register `GameAiAgentProvider` through the existing registry. For a scene host,
use `AgentRegistryPlugin` and `AgentProviderPlugin`; renderer-free hosts can keep
the returned registry registration for their lifetime. Read tools require
`ai.read`; reset/model selection require `ai.control` plus host gameplay approval,
current revision and a retry key. Team communication has no external tool.

Passive tools expose permitted observations, memory ages, goals, model hashes,
actual request/staged due ticks and existing decision receipts. Observation
values and receipt history are bounded. Unknown native arena bytes remain null.
The optional `zyren_ml/agents.dart` provider exposes native admission counters and
registered model pins under `ml.read`; optional host commands use `ml.control`.
The `zyren_ml.dart` inference entry retains no scene import.

Reuse the existing Devtools telemetry, agent job history and `zyren_devtools:zyren`
CLI/MCP transport. No MCP server or remote model service is required for play.
The macOS CPU probe uses actual Rapier and ONNX Runtime, including shared LSTM
weights, isolated recurrent rows, actor replacement and reward isolation. An
external existing MCP process inspects the live host, resets and selects models,
then verifies denied, stale and cancelled commands. Rendering in those runtime
fixtures is a presentation test double; the A6 GPU probe remains separate.
