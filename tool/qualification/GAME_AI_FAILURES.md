# Failure and recovery receipts

Run `python3 tool/qualification/verify_game_ai_failures.py` from the workspace root. The case registry is game_ai_failure_matrix.json. Its 25 fixed case IDs cover project data, identity, native model/sensor ownership, queues, cancellation, worker/renderer loss, save/editor transactions, information boundaries and external tools.

Use `--check-schema` while collecting evidence. A blocked case needs a reason. Qualification fails until every required case has passed; absent cases and silent skips always fail.

Each passed registry case points to a repository-relative execution JSON file through evidence.path and evidence.sha256. That receipt has schemaVersion 1 and a cases map keyed by the registry IDs. Each case contains:

- status passed and actualStatus matching the registry expectedStatus.
- before and after maps containing the complete preserved session/document identity receipt. Both maps must be equal, including fields outside the named preservedIdentities list.
- cleanupCounters.before and cleanupCounters.after maps with nonnegative integer resource counts that return to baseline.
- recovery with the registry action and status passed, after exercising the retry/recovery.
- execution with kind pure or native, the actual command and exitCode 0. Native lifetime and perception cases require native execution.

Core receipts come from real rejection/recovery tests:

```sh
GAME_FAILURE_RECEIPT_PATH="$PWD/tool/qualification/receipts/game-core.json" fvm dart --packages=.dart_tool/package_config.json packages/zyren_game/test/failure_matrix_test.dart
```

The six tests compare the encoded save plus epoch, revision, complete entity handles, queue count and fault before/after rejection. Each session closes and its live-session counter returns to zero. The tracked receipt records the checked run. Re-run a package's tests and refresh its content pin when evidence changes; do not mark a case passed from a source link or a test name.

The current registry explicitly records pending cross-package receipts. Existing regressions may cover those cases, but they have not yet supplied the consolidated identity/cleanup record. Synthetic evaluator unit-test receipts check the verifier and do not qualify a game backend.
