# Game and AI release audit

The implementation is locally usable for the structured reference games. It is not a complete platform release. [completion.json](completion.json) retains all 32 requirements, all 32 tasks and the five required native targets. Schema validation accepts explicit blockers; release validation deliberately fails while those blockers remain.

## What the evidence establishes

| Area | Recorded result | Remaining limit |
| --- | --- | --- |
| Project, Studio, controllers and offline host | Versioned components, persisted prefab overrides, isolated play, native characters/vehicles, pools, checkpoints and Pipeline export have checked regression paths | A fresh independent checkout and complete physical input/accessibility pass remain required |
| Failure matrix | All 25 strict identity/status/recovery/cleanup rows pass with pinned execution receipts | Metal renderer injection is real native surface revocation, not physical GPU removal |
| Structured models | Guard and vehicle accepted ONNX actors each pass 200 held-out episodes; 1,000 Dart/native tensor/control parity steps per family | Quality applies to the locked cases and seeds, not every authored level |
| Quantization | Local int8 candidates pass quality and native parity, with zero measured success loss and reduced model bytes | They are not accepted application defaults; binary and working-memory savings are unknown |
| Camera observations | Actual native RGB/depth capture and permitted tensor preprocessing are implemented and tested | No accepted trained visual policy or visual capacity profile exists |
| Multi-agent training | Same-runtime tasks, historical team state and controlled opponent selection have foundation regressions | Cooperative/competitive trained artifacts and held-out quality/scaling acceptance remain incomplete |
| Mobile ML | Physical Pixel 9 Pro and Apple arm64 simulator execute the native ML probe; unsigned iOS device build exists | ML probe execution does not qualify game rendering/input or sustained capacity; physical Apple signing/inference remains blocked |
| Performance | Full-step and per-system timing, deadline accounting, native owner cleanup and opt-in benchmark orchestration exist | The initial physical Android timing failure is retained; no ten-minute, three-run capacity pass is claimed |
| Publication | Runtime excludes Studio/Python; API generator registers the optional packages | Public dependency versions, code/model redistribution terms, native signing and publish dry runs remain unresolved |

The original T5 evaluation plan and failed checkpoint receipts remain immutable. The audited revision changes only frozen worker artifact identity and revision metadata, preserving canonical cases, seeds, partitions and thresholds. The accepted float hashes are `34c738fe968a80442fdb70fc4187ff366248003384082ac8e29ef0e0470a48c0` for guard and `15cbd7d4f30bba4cb5e506e7308adf7d17a42c653d6564d25183545ddde82e66` for vehicle.

## Reuse checked against the implementation

| Responsibility | Existing owner | Game extension and audit result |
| --- | --- | --- |
| Authored graph, prefabs, history, revisions | Studio | Game components use extensions/overrides and validated editor commands; compiler consumes expanded saved data |
| Docking and editor lifetime | Flutter Studio host | Contributions register actual panes, tools, commands and play owners; teardown drains the renderer and preparation leases |
| Pointer, keyboard focus and modal ownership | InputRouter and Interaction | GameSceneBinding composes existing SceneView/overlay and releases held semantic actions on authority changes |
| Native rendering and resources | NativeBackend, SceneEngine and attachment scopes | Game runtime supplies plugins; camera sensors use Capture and immutable native FrameSubmission |
| Physics and animation | Rapier, PhysicsPlugin, CharacterMotor and Timeline | One game clock drives one physical step; animation checkpoint seams extend the existing owners |
| Asset identity, bundles, cache and jobs | Pipeline | Compiled recipe is a pinned bundle resource; export uses Pipeline jobs and host-selected publication |
| Scoped assistant and external tools | Agents and Devtools | Game/AI providers register current revision, grants, bounded retry identity and owner-scoped cancellation |
| Collaboration | Collaboration | Unsupported connected component operations reject explicitly; no game-specific networking protocol was introduced |
| Training | Separate native worker and Python toolchain | The worker calls shipped native controllers; Python owns learning and never enters the Flutter runtime dependency closure |

No reverse game/ML imports were found in core renderer packages during this audit. The package boundary checker and API generator already register the new optional packages. Shared renderer changes remain with their owner.

## Dependency, licensing and packaging closure

The five new game/editor packages are `publish_to: none`, version 0.1.0, with workspace path dependencies. They are not publishable artifacts. They now have local changelogs, but neither those packages nor the repository root provide a public code redistribution license. Do not invent a license or remove the private declaration to obtain a dry-run pass.

Existing renderer/importer/compression dependencies retain [third-party notices](../../../THIRD_PARTY_NOTICES.md) and [license texts](../../../licenses/); Physics retains its generated Rust dependency licenses under `packages/zyren_physics/licenses`. These notices do not supply a new public code/model license for the game packages.

ONNX Runtime 1.23.2 retains its existing LICENSE and NOTICES under `packages/zyren_ml/native`. Accepted model provenance says repository-authored local recordings/weights and `LicenseRef-Repository-Authored`; that label records origin and is explicitly not a public redistribution grant. Reference primitive, buggy and skinned fixtures are authored through repository geometry/glTF helpers. Asset licenses must still be reviewed for any user-imported model before distributing a bundle.

Native physics, renderer and ML keep their existing C ABI/hook owners. Mobile ML cross-builds and simulator results do not substitute for physical Vulkan/Metal gameplay qualification. Apple provisioning/App ID quota currently prevents a physical-device ML run. Windows/Linux full game qualification, per-platform signing and binary size/working-memory accounting remain open.

Publish dry runs are blocked for these private path-dependent packages. No publication, registry upload, signing change or website publication occurred. A fresh dependency-resolved checkout, public package version resolution and explicit license decisions are still required before dry runs can establish readiness.

## Reproduce the strict gates

From the repository root:

```sh
python3 -m unittest discover -s tool/qualification/tests -v
python3 tool/qualification/verify_game_ai_failures.py
python3 tool/qualification/verify_game_ai_release.py --check-schema
python3 tool/qualification/verify_game_ai_release.py
```

The failure evaluator passes all 25 rows. The completion schema check must pass with full coverage and unchanged evidence pins. The final release command is expected to fail on the explicit outstanding gates. A skipped device job cannot turn any native target green.

Native packages run sequentially. Required GPU jobs remain opt-in on a configured physical runner and upload their logs even when they fail. See the [first-game guide](../../../packages/zyren_game/GUIDE.md), [native host guide](../../../packages/zyren_game_native/GUIDE.md), [AI tools](../../../packages/zyren_game_studio/doc/ai-training.md), [training operators](../../../tool/zyren_train/README.md) and [model qualification](../../../tool/zyren_train/qualification/2026-10-03/README.md).
