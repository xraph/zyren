# Game development, Studio and learned AI

You should be able to build a game in Zyren Studio, run it in a native Flutter app,
and train characters or vehicles against the same simulation. This plan covers
the runtime, the editor tools, perception, model execution and the training setup.

Status: partial implementation, 2026-10-03. Structured reference games, Studio tools, native ML and accepted guard/vehicle policies have checked local workflows. Visual/multi-agent trained acceptance, sustained capacity, full physical target coverage, native accessibility and publication remain incomplete. See [completion.json](completion.json) and [the release audit](release-audit.md).

## Read and implement in this order

| Document | What you get | Task IDs |
| --- | --- | --- |
| [Existing plugin reuse audit](reuse-audit.md) | Current owners, duplication removed and the remaining game/ML gaps | Applies to all tasks |
| [Design and contracts](design.md) | Scope, package boundaries, saved data, simulation and model contracts | Requirements R01-R32 |
| [Game runtime](01-game-runtime.md) | Reusable game development APIs, native actors, vehicles, rules and saves | G1-G7 |
| [Studio integration](02-studio-editor.md) | Editor extension API, component authoring, play mode, AI tools and export | S1-S7 |
| [AI and perception](03-ai-perception.md) | Native inference, sensors, memory, learned policies and camera observations | A1-A7 |
| [Training](04-training.md) | Environment workers, demonstrations, training, export and reproducible evaluation | T1-T6 |
| [Qualification and delivery](05-qualification.md) | Integrated examples, device budgets, failure checks, docs and release gates | Q1-Q5 |

These are separate plans because you can review and test each subsystem without
waiting for the entire program. They share the contracts in `design.md`. New API
names in the plans are proposals; existing APIs are identified in the source audit.

## Product decisions

- The game plugin supports game development generally: levels, entities,
  components, input, cameras, interactions, rules, inventory, abilities, spawning,
  save games, debugging and packaging. Character control is one part of it.
- Studio is the authoring host. Game tools contribute to its hierarchy,
  inspectors, asset library, commands, viewport and history. You do not maintain
  another editor or another scene graph.
- Existing plugins own authored prefabs/history, pointer arbitration, scene
  widgets, asset bundles/caches, agent workflows and capture infrastructure.
  Game tasks extend those APIs. The reuse audit records the exact boundaries.
- The generic ML plugin loads and executes versioned models. Gameplay sensors,
  goals, memory and action decoding belong in a separate game adapter.
- Structured sensors and actual camera perception are both in scope. Shipping
  structured sight does not close the camera work.
- Training uses the shipped game simulation and native physics. Python owns the
  training algorithms; the game owns observations and actions.
- Native Metal, Vulkan and DX12 remain the rendering backends. Training workers
  can run without rendering when their observation profile does not need pixels.

## Delivery sequence

| Milestone | Prerequisites | Reviewable result |
| --- | --- | --- |
| M0: contracts and host foundations | G1, S1, A1 | A saved game component survives Studio reload, and a real tiny model passes the native tensor contract probe |
| M1: playable game from Studio | G2-G7, S2-S4 | Author a level, control a character, drive a vehicle, pause, step and stop without changing the authored scene |
| M2: complete development workflow | S5, S7 | Author rules and templates, inspect build diagnostics and export an offline native game |
| M3: perceptive scripted actors | A2-A4, T1 | Inspect NPC observations and memory through runtime diagnostics; run the same scenario through the training protocol |
| M4: trained structured policies | A5, T2-T5 | Train, evaluate, import and run character and vehicle policies in the exported game |
| M5: camera and multi-agent behavior | A6-A7, T6, S6 | Native RGB/depth observations, learned visual behavior, cooperation and competition, plus the complete Studio AI/training workspace |
| M6: qualified delivery | Q1-Q5 | Recorded platform results, supported budgets, documentation and remaining blockers |

G1 and S1 define the shared document contract first. A1's model probe can run
independently after its manifest is defined. Camera readback and recurrent ONNX
export are early feasibility checks, even though their complete features land in
M5 and M4. A failed probe changes the implementation choice before dependent work
starts. It does not remove the required feature from the completion matrix.

Task dependencies are below. Complete an earlier task against its real contract
fixtures; Q1 then verifies the full workflow using trained and exported artifacts.
Do not make a foundational task wait for a later integration test that needs it.

| Task | Required completed tasks |
| --- | --- |
| G1 | None |
| G2 | G1 |
| G3 | G2 |
| G4 | G2, G3 |
| G5 | G2, G3, G4 |
| G6 | G1, G2, G4 |
| G7 | G2, G5, G6, S1 |
| S1 | G1 |
| S2 | S1 |
| S3 | S2, G4, G5, G6, G7 |
| S4 | S3, G7 |
| S5 | S3, G7 |
| S7 | S4, S5, G7 |
| A1 | None |
| A2 | A1 |
| A3 | G4, G5, G6, A1 |
| A4 | A3, G6 |
| A5 | A2, A4 |
| A6 | A1, A3, G2 |
| A7 | A4, A5 |
| T1 | G7, A3, A4 |
| T2 | T1 |
| T3 | T2, A5 |
| T4 | T3 |
| T5 | T4, A1, A5 |
| T6 | T5, A6, A7 |
| S6 | S4, A5, A6, A7, T6 |
| Q1 | S5, S6, S7, T6 |
| Q2 | Q1 |
| Q3 | Q1 |
| Q4 | Q1, Q2 |
| Q5 | Q2, Q3, Q4 |

## Working assumptions

The initial templates are an exploration game with NPCs and a vehicle playground.
Desktop authoring and offline mobile/desktop play set the default constraints.
The first release includes wheeled vehicles; aircraft and boats use the same
controller interface but need their own later physics and training profiles.

Python training is an optional workstation toolchain. A CUDA workstation is a
candidate for larger runs, while CPU training must work for protocol and small
policy checks. Hardware cost and training duration are measured during T1/T3.
No cloud resource, paid run or model download is authorized by this plan.

A general dialogue model, generated quests, arbitrary executable mods, production
multiplayer replication and learned muscle-level locomotion are separate future
projects. This plan includes the extension points and records that boundary in
the design. They are not requirements for the requested game development and
perception workflow.

## Ownership and execution

This planning change owns only `plans/zyren-plugins/game-ai/**`. Other plugin
plans, source packages and the Studio mock remain owned by their current work.
Root `docs/` is ignored in this repository, so the durable plan lives beside the
existing tracked plugin plans.

When implementing, inspect the current source and staged changes before each
task. Shared-file requests appear in the owning plan. Use the existing
`/tmp/zyren-plugin-expansion.lock` for shared edits, dependency resolution and Git
index operations. Never remove a foreign lock. Native hook builds and device
sessions must be coordinated separately; the Git lock stays brief.

Use Flutter 3.47.5 through FVM and the existing native Rust toolchain where a task
touches it. Stay on the active branch. Make focused local commits after relevant
checks, preserve concurrent changes, and do not push or merge. Repository prose
uses rex-voice and humanizer in embedded mode, without em dashes or attribution
trailers.

## Completion record

| Area | Implementation | Automated checks | Live verification |
| --- | --- | --- | --- |
| Shared Studio/input/physics/animation/Pipeline owners | Reused through public adapters | Source/regression audit and recorded affected checks | Full physical input/accessibility and fresh-checkout gate remain open |
| Game runtime and Studio game tools | Project/components, isolated play, controllers, pools, native saves, export | Checked contracts and actual Studio/native fixtures | macOS Metal surface loss/recreation passes; no whole-platform qualification |
| Native ML, perception and memory | Bounded native execution, permitted sensors, current-generation controllers and recurrent state | Native controller/inference/checkpoint/leakage regressions | Physical Android ML and Apple simulator probe pass; full target gameplay is incomplete |
| Structured training and parity | Accepted float guard and vehicle ONNX actors | 400 held-out episodes and 1,000 native typed/tensor steps per family | Accepted locked distributions; no universal gameplay or capacity claim |
| Camera and multi-agent policies | Real native camera tensors and training foundations | Capture, worker/protocol and teacher/failure checks | No accepted visual or cooperative/competitive learned artifact |
| Failure/recovery and release | All 25 failure rows pinned; release evaluator retains all 32 requirements/tasks | Failure gate passes; completion schema passes | Release remains blocked by explicit delivery gates |

The completion ledger distinguishes implementation, automated checks, native execution, accepted models and documentation. It retains all five physical target requirements. A smoke run, cross-build, source hash or skipped GPU job cannot satisfy those gates.

Planning checks passed for eight linked documents, 32 uniquely assigned tasks,
32 mapped requirements and an acyclic task dependency graph. Local links, code
fences, embedded JSON/Python syntax and prose dash constraints were checked.
These checks validate the plan's structure; they do not establish implementation,
model quality or device performance.

The reuse audit inventories all 30 current packages and records ten areas where
the tasks now reuse or extend an existing owner. Recheck those source boundaries
before implementation, especially the active Studio and renderer work.
