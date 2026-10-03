# Runtime persistence and project compilation

You can compile Studio documents through `zyren_game_studio/compiler.dart`, export a Pipeline bundle, and load its pinned game recipe without importing Studio or Pipeline into the runtime. The compiler reuses Pipeline build jobs, transforms, receipts, byte limits and cache APIs. Scene nodes and prefab component overrides use the existing Studio format.

Register a `GameStateCodec` for each live mutable system before saving. Restore prepares replacement and rollback states before changing the entity table, commits synchronously, and restores the original table and codec states if a commit fails. A rollback or staging cleanup failure faults the session. Codecs release uncommitted resources through `discard`; after a successful commit, the live system owns them. Unknown required components, missing codec versions and changed model/build pins prevent activation or restore.

`GameLevelManager` owns prepared candidates and asset leases. A later preparation retires earlier prepared candidates. Unload invalidates pending loads and closes prepared and active levels. Asset resolvers must cooperate with cancellation and must return an owned lease for each successful request. `cleanupFailure` retains failures from resource release or cancellation callbacks. Native allocations made by a system factory before returning its systems remain the factory's responsibility.

Use `FileGameSaveStore` from the optional `zyren_game/io.dart` entrypoint for runtime save slots. Writes use a flushed staging file, slot locks and rename. A failed publication preserves the previous published save; the next read removes abandoned slot staging files. Filesystem guarantees still apply. Power-loss durability and Windows replacement behavior have not been qualified.

The focused checks on 2026-10-03 passed:

- 18 Dart runtime tests cover save migration, pooling generations, staged codec failures and rollback, model and codec pins, interrupted loads, prepared-candidate cleanup, concurrent unload, disk restart, failed publication, replay identity, scoped MCP controls and diagnostics history.
- Five compiler tests cover Pipeline reuse, nested prefab overrides and references, custom attached entity identities, pinned binary/model assets, offline load, capability rejection and failed/cancelled builds.
- One native Rapier lifetime fixture passed 50 load/unload cycles and partial initialization cleanup, with tracked world owners returning to their captured baseline. This native run preceded the final prepared-candidate and activation-race repair; those paths have subsequent Dart regression coverage.
- Analysis is clean for the changed runtime, compiler and test files.

These checks do not qualify a renderer, physical device, every native subsystem's allocation counts, crash durability or cross-platform file replacement. You still need device and backend qualification for the capabilities selected in a build profile.
